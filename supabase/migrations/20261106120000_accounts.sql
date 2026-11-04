-- Счета со стартовым остатком (ADR-0008, док 02 раздел 2, док 05). Без поля владельца
-- (spec.md): счета различаются только названием. Остаток и аванс не хранятся, их даёт журнал.

create type public.account_type as enum ('card', 'bank_account', 'cash');

create table public.accounts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (name = btrim(name) and name <> ''),
  bank        text check (bank = btrim(bank) and bank <> ''),  -- у наличных нет
  type        public.account_type not null,
  mask        text check (mask = btrim(mask) and mask <> ''),
  currency    text not null default 'KZT' check (currency ~ '^[A-Z]{3}$'),
  start_date  date not null,  -- дата старта счёта, потом неизменна (ADR-0008)
  is_archived boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint accounts_cash_has_no_bank check (type <> 'cash' or bank is null),
  -- Для составных FK: запись и журнал ссылаются только на счета того же пользователя.
  constraint accounts_user_id_id unique (user_id, id)
);

create unique index accounts_user_name on public.accounts (user_id, name);
create index accounts_user_archived on public.accounts (user_id, is_archived);

-- Счёт с записями не удалить (док 02): FK с restrict. Журнал пересобирается целиком,
-- поэтому его ссылка тоже restrict, а не cascade.
alter table public.entries
  add constraint entries_account_fk foreign key (user_id, account_id)
    references public.accounts (user_id, id) on delete restrict,
  add constraint entries_to_account_fk foreign key (user_id, to_account_id)
    references public.accounts (user_id, id) on delete restrict;
alter table public.ledger_entries
  add constraint ledger_account_fk foreign key (user_id, account_id)
    references public.accounts (user_id, id) on delete restrict;

create index entries_to_account on public.entries (user_id, to_account_id) where to_account_id is not null;

-- С клиента счета только читаются: создание, правка, архив и удаление через RPC с проверками.
select public.apply_user_rls('public.accounts');
revoke all on public.accounts from authenticated;
grant select on public.accounts to authenticated;

-- Движок: корректировка с целью «остаток» (док 03, 4.7). Тело заменяет версию из тикета 05,
-- долговая цель не изменилась.

-- Валюта счёта для дельты остатка (док 03, раздел 5).
create function engine.account_currency(p_account uuid) returns text
language sql stable as $$ select currency from public.accounts where id = p_account $$;

-- Дельта остатка в валюте счёта: тенговый счёт двигается тенговым эквивалентом,
-- счёт в валюте операции её суммой (док 03, раздел 5).
create function engine.balance_amount(e public.entries, p_account uuid) returns bigint
language sql stable as $$
  select case when engine.account_currency(p_account) = 'KZT' then e.amount_kzt_minor else e.amount_minor end
$$;

create or replace function engine.apply_adjustment(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  v_delta bigint := e.adjustment_sign * e.amount_kzt_minor;
  v_side  public.ledger_target;
begin
  case e.adjustment_target
    when 'company_owes_me', 'i_owe_company' then
      v_side := e.adjustment_target::text::public.ledger_target;
      if engine.debt_of(st, v_side) + v_delta < 0 then
        perform engine.fail('debt_below_zero', e,
          jsonb_build_object('side', v_side, 'available_minor', engine.debt_of(st, v_side)));
      end if;
      return engine.post(st, e, v_side, null, v_delta);
    when 'balance' then
      st := engine.post(st, e, 'balance', e.account_id,
                        e.adjustment_sign * engine.balance_amount(e, e.account_id));
      if e.adjustment_affects_advance then
        -- Аванс не уходит в минус: минус режется на доступном авансе.
        st := engine.post(st, e, 'card_advance', e.account_id,
                          greatest(v_delta, -engine.advance_of(st, e.account_id)));
      end if;
      return st;
  end case;
end $$;

-- Поля счёта от клиента: название обязательно, валюта ISO-кодом.
create function engine.check_account_fields(p_name text, p_currency text) returns void
language plpgsql immutable as $$
begin
  if p_name is null or btrim(p_name) = '' then
    perform engine.raise_error('missing_required', '{"field": "name"}');
  end if;
  perform engine.check_currency(p_currency);
end $$;

create function engine.check_currency(p_currency text) returns void
language plpgsql immutable as $$
begin
  if p_currency is not null and p_currency !~ '^[A-Z]{3}$' then
    perform engine.raise_error('currency_invalid', jsonb_build_object('currency', p_currency));
  end if;
end $$;

-- Стартовый остаток (ADR-0008): «всего на счёте» и «из них компании» не меньше нуля,
-- компании не больше всего (свои = разница, не в минусе). Аванс ведётся в тенге, а тенговый
-- эквивалент валютных сумм появится с валютой (тикет 14): до тех пор стартовый остаток
-- валютного счёта только нулевой.
create function engine.check_opening(p_currency text, p_total bigint, p_company bigint) returns void
language plpgsql immutable as $$
begin
  if p_total is null or p_company is null then
    perform engine.raise_error('missing_required', '{"field": "amount"}');
  end if;
  if p_total < 0 or p_company < 0 then
    perform engine.raise_error('amount_negative');
  end if;
  if p_company > p_total then
    perform engine.raise_error('opening_advance_too_big',
      jsonb_build_object('total_minor', p_total, 'company_minor', p_company));
  end if;
  if p_currency <> 'KZT' and p_total > 0 then
    perform engine.raise_error('foreign_opening_not_supported', jsonb_build_object('currency', p_currency));
  end if;
end $$;

-- Создание счёта (док 05, ADR-0008): счёт и стартовый остаток на дату старта двумя
-- корректировками остатка (скрыты, вне разрезов трат): свои = всего − компании без аванса
-- и «из них компании» с авансом. Затем пересчёт. Возвращает { ok, account_id, warnings }.
create function public.create_account(
  p_name          text,
  p_type          public.account_type,
  p_currency      text   default 'KZT',
  p_start_date    date   default null,
  p_total_minor   bigint default 0,
  p_company_minor bigint default 0,
  p_bank          text   default null,
  p_mask          text   default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_date date := coalesce(p_start_date, (now() at time zone 'Asia/Almaty')::date);
  v_start date;
  v_id   uuid;
  v_part record;
begin
  perform public.assert_allowed();
  perform engine.check_account_fields(p_name, coalesce(p_currency, 'KZT'));
  if p_type is null then
    perform engine.raise_error('missing_required', '{"field": "type"}');
  end if;
  perform engine.check_opening(coalesce(p_currency, 'KZT'), p_total_minor, p_company_minor);
  select accounting_start_date into v_start from public.user_settings where user_id = v_uid;
  if v_start is null then
    perform engine.raise_error('start_not_set');
  end if;
  if v_date < v_start then
    perform engine.raise_error('entry_before_start',
      jsonb_build_object('start_date', v_date, 'accounting_start_date', v_start));
  end if;

  insert into public.accounts (user_id, name, bank, type, mask, currency, start_date)
  values (v_uid, btrim(p_name), case when p_type <> 'cash' then nullif(btrim(p_bank), '') end, p_type,
          nullif(btrim(p_mask), ''), coalesce(p_currency, 'KZT'), v_date)
  on conflict (user_id, name) do nothing
  returning id into v_id;
  if v_id is null then
    perform engine.raise_error('account_name_taken', jsonb_build_object('name', btrim(p_name)));
  end if;

  for v_part in
    select * from (values (p_total_minor - p_company_minor, false), (p_company_minor, true)) p (amount, with_advance)
    where amount > 0
  loop
    insert into public.entries (user_id, type, occurred_on, amount_minor, currency, amount_kzt_minor, account_id,
                                adjustment_mode, adjustment_sign, adjustment_target, adjustment_affects_advance,
                                in_analytics, title)
    values (v_uid, 'adjustment', v_date, v_part.amount, coalesce(p_currency, 'KZT'), v_part.amount, v_id,
            'plug_hidden', 1, 'balance', v_part.with_advance, false, 'Стартовый остаток');
  end loop;

  return jsonb_build_object('ok', true, 'account_id', v_id) || engine.recompute(v_uid);
end $$;

revoke all on function public.create_account(text, public.account_type, text, date, bigint, bigint, text, text)
  from public, anon;
grant execute on function public.create_account(text, public.account_type, text, date, bigint, bigint, text, text)
  to authenticated;

-- Выборка «остатки по счетам» (док 05): остаток, аванс и свои по каждому счёту, только из журнала.
create view public.v_account_balances with (security_invoker = true) as
select a.id as account_id, a.name, a.bank, a.type, a.mask, a.currency, a.start_date,
       coalesce(l.balance, 0)::bigint                        as balance_minor,
       coalesce(l.advance, 0)::bigint                        as advance_minor,
       (coalesce(l.balance, 0) - coalesce(l.advance, 0))::bigint as own_minor,
       a.is_archived,
       exists (select 1 from public.entries e
               where e.account_id = a.id or e.to_account_id = a.id) as has_entries
from public.accounts a
left join (
  select account_id,
         sum(delta_minor) filter (where target = 'balance')      as balance,
         sum(delta_minor) filter (where target = 'card_advance') as advance
  from public.ledger_entries
  where user_id = (select auth.uid()) and account_id is not null
  group by account_id
) l on l.account_id = a.id
where a.user_id = (select auth.uid());

revoke all on public.v_account_balances from anon, authenticated;
grant select on public.v_account_balances to authenticated;

-- Свой счёт по id или ошибка account_not_found (чужой счёт не видно так же, как несуществующий).
create function engine.own_account(p_user uuid, p_account uuid) returns public.accounts
language plpgsql stable as $$
declare
  a public.accounts;
begin
  select * into a from public.accounts where id = p_account and user_id = p_user;
  if not found then
    perform engine.raise_error('account_not_found', jsonb_build_object('account_id', p_account));
  end if;
  return a;
end $$;

-- Остаток и аванс счёта из журнала (последний пересчёт).
create function engine.account_counters(p_account uuid, out balance_minor bigint, out advance_minor bigint)
language sql stable as $$
  select coalesce(sum(delta_minor) filter (where target = 'balance'), 0)::bigint,
         coalesce(sum(delta_minor) filter (where target = 'card_advance'), 0)::bigint
  from public.ledger_entries where account_id = p_account
$$;

-- Архив (док 05): только при нулевых остатке и авансе, история остаётся.
create function public.archive_account(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.accounts;
  c record;
begin
  perform public.assert_allowed();
  a := engine.own_account(auth.uid(), p_account_id);
  select * into c from engine.account_counters(a.id);
  if c.balance_minor <> 0 or c.advance_minor <> 0 then
    perform engine.raise_error('archive_nonzero', jsonb_build_object(
      'account_id', a.id, 'balance_minor', c.balance_minor, 'advance_minor', c.advance_minor));
  end if;
  update public.accounts set is_archived = true, updated_at = now() where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

create function public.unarchive_account(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.accounts;
begin
  perform public.assert_allowed();
  a := engine.own_account(auth.uid(), p_account_id);
  update public.accounts set is_archived = false, updated_at = now() where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.archive_account(uuid), public.unarchive_account(uuid) from public, anon;
grant execute on function public.archive_account(uuid), public.unarchive_account(uuid) to authenticated;

-- Удаление (док 05): только счёт без записей (черновики тоже записи). С записями только архив.
create function public.delete_account(p_account_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.accounts;
begin
  perform public.assert_allowed();
  a := engine.own_account(auth.uid(), p_account_id);
  if exists (select 1 from public.entries where account_id = a.id or to_account_id = a.id) then
    perform engine.raise_error('account_delete_forbidden', jsonb_build_object('account_id', a.id));
  end if;
  delete from public.accounts where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.delete_account(uuid) from public, anon;
grant execute on function public.delete_account(uuid) to authenticated;

-- Правка (док 04, раздел 2): название, банк, маска и валюта целиком (пустое значение очищает
-- банк и маску; валюта null = не менять). Тип и дата старта не меняются. Валюту счёта с
-- записями менять нельзя: суммы в истории в ней.
create function public.update_account(
  p_account_id uuid,
  p_name       text,
  p_bank       text default null,
  p_mask       text default null,
  p_currency   text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.accounts;
begin
  perform public.assert_allowed();
  a := engine.own_account(auth.uid(), p_account_id);
  if p_currency is not null and p_currency <> a.currency
     and exists (select 1 from public.entries where account_id = a.id or to_account_id = a.id) then
    perform engine.raise_error('account_currency_locked', jsonb_build_object('account_id', a.id));
  end if;
  perform engine.check_account_fields(p_name, p_currency);
  update public.accounts
     set name       = btrim(p_name),
         bank       = case when a.type <> 'cash' then nullif(btrim(p_bank), '') end,
         mask       = nullif(btrim(p_mask), ''),
         currency   = coalesce(p_currency, a.currency),
         updated_at = now()
   where id = a.id;
  return jsonb_build_object('ok', true);
exception when unique_violation then
  perform engine.raise_error('account_name_taken', jsonb_build_object('name', btrim(p_name)));
end $$;

revoke all on function public.update_account(uuid, text, text, text, text) from public, anon;
grant execute on function public.update_account(uuid, text, text, text, text) to authenticated;

-- Предпросмотр стартового остатка для формы создания: свои = всего − компании с теми же
-- проверками, что у create_account. Клиент денег не считает (ADR-0010). Ничего не пишет.
create function public.preview_account_opening(
  p_total_minor   bigint,
  p_company_minor bigint,
  p_currency      text default 'KZT'
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.assert_allowed();
  perform engine.check_currency(p_currency);
  perform engine.check_opening(coalesce(p_currency, 'KZT'), p_total_minor, p_company_minor);
  return jsonb_build_object('own_minor', p_total_minor - p_company_minor);
end $$;

revoke all on function public.preview_account_opening(bigint, bigint, text) from public, anon;
grant execute on function public.preview_account_opening(bigint, bigint, text) to authenticated;

-- Движок закрыт: его функции зовут только RPC выше.
revoke all on all functions in schema engine from public;
