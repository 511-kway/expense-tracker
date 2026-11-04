-- Движок расчёта: записи, журнал движений, полный пересчёт; первый запуск и стартовый долг.
-- ADR-0002 (журнал как источник правды), ADR-0006 (проверки «до нуля» реплеем),
-- ADR-0008 (дата начала учёта, стартовый долг). Схема по доку 02 с поправками spec.md:
-- новый тип «взаимозачёт» (netting), без transfer_purpose top_up_advance, без владельца счёта.

-- 1. Перечисления (док 02, раздел 1). account_type и note_status появятся со своими таблицами.

create type public.entry_type as enum (
  'expense',                 -- трата
  'income',                  -- поступление
  'transfer',                -- перевод
  'company_topup',           -- пополнение от компании
  'company_advance_return',  -- изъятие аванса
  'settlement',              -- погашение долга
  'netting',                 -- взаимозачёт
  'adjustment',              -- корректировка
  'refund'                   -- возврат покупки
);
create type public.entry_status as enum ('draft', 'done');
create type public.purpose as enum ('personal', 'work');
create type public.money_source as enum ('own', 'company');
create type public.transfer_purpose as enum ('repay_debt', 'take_advance', 'move_own', 'move_company');
create type public.fee_payer as enum ('own', 'company');
create type public.rate_source as enum ('nbk', 'manual', 'derived');
create type public.settlement_direction as enum ('i_paid_company', 'company_paid_me');
create type public.adjustment_mode as enum ('plug_hidden', 'plug_analytics');
create type public.adjustment_target as enum ('balance', 'company_owes_me', 'i_owe_company');
create type public.ledger_target as enum ('balance', 'card_advance', 'company_owes_me', 'i_owe_company');

-- 2. Настройки пользователя. Строка появляется только в setup_start: её наличие и есть
-- «первый запуск пройден». Дата начала учёта потом неизменна (ADR-0008).

create table public.user_settings (
  user_id               uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  accounting_start_date date not null,
  timezone              text not null default 'Asia/Almaty',
  default_currency      text not null default 'KZT' check (default_currency ~ '^[A-Z]{3}$'),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- 3. Записи: все типы в одной таблице, поля по типу nullable (док 02, раздел 4, матрица).
-- Ссылки на accounts, categories, notes, import_batches получат FK вместе со своими таблицами.

create table public.entries (
  id                         uuid primary key default gen_random_uuid(),
  user_id                    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  type                       public.entry_type not null,
  status                     public.entry_status not null default 'done',
  occurred_on                date not null,
  occurred_at                timestamptz,
  amount_minor               bigint not null check (amount_minor > 0),
  currency                   text not null default 'KZT' check (currency ~ '^[A-Z]{3}$'),
  amount_kzt_minor           bigint check (amount_kzt_minor > 0),
  rate                       numeric(18, 8) check (rate > 0),
  rate_source                public.rate_source,
  account_id                 uuid,  -- для перевода «откуда»; FK в тикете 06
  to_account_id              uuid,  -- только перевод, «куда»
  category_id                uuid,  -- FK в тикете 07
  purpose                    public.purpose,
  source                     public.money_source,
  source_pending             boolean not null default false,
  transfer_purpose           public.transfer_purpose,
  fee_minor                  bigint not null default 0 check (fee_minor >= 0),
  fee_payer                  public.fee_payer,
  settlement_direction       public.settlement_direction,
  adjustment_mode            public.adjustment_mode,
  adjustment_sign            smallint check (adjustment_sign in (1, -1)),
  adjustment_affects_advance boolean not null default false,
  adjustment_target          public.adjustment_target,
  in_analytics               boolean not null default true,
  comment                    text,
  title                      text,
  parent_entry_id            uuid references public.entries (id) on delete restrict,
  source_note_id             uuid,  -- FK в тикете 16
  fingerprint                text,
  external_id                text,
  import_batch_id            uuid,  -- FK в тикете 18
  seq                        bigint generated always as identity unique,  -- номер вставки, последний тайбрейк
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),

  -- Учтённой записи нужен тенговый эквивалент; черновик может ждать курса.
  constraint entries_done_has_kzt check (status = 'draft' or amount_kzt_minor is not null),
  constraint entries_to_account check (
    to_account_id is null or (type = 'transfer' and to_account_id is distinct from account_id)),
  constraint entries_adjustment_fields check (
    type <> 'adjustment'
    or (adjustment_sign is not null and adjustment_target is not null and adjustment_mode is not null
        and (adjustment_target = 'balance') = (account_id is not null)))
);

create index entries_user_occurred on public.entries (user_id, occurred_on);
create index entries_user_account_occurred on public.entries (user_id, account_id, occurred_on);
create index entries_user_fingerprint on public.entries (user_id, fingerprint);
create index entries_user_status on public.entries (user_id, status);
create index entries_parent on public.entries (parent_entry_id);
create unique index entries_external_id on public.entries (user_id, import_batch_id, external_id)
  where external_id is not null;

-- 4. Журнал движений: каждая строка двигает один счётчик на дельту. Пишет только движок.

create table public.ledger_entries (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  entry_id    uuid not null references public.entries (id) on delete cascade,
  account_id  uuid,
  target      public.ledger_target not null,
  delta_minor bigint not null,  -- остаток в валюте счёта; аванс и долг в тиынах
  occurred_on date not null,
  seq         bigint not null,
  created_at  timestamptz not null default now(),
  constraint ledger_account_target check ((target in ('balance', 'card_advance')) = (account_id is not null))
);

create index ledger_user_account_target on public.ledger_entries (user_id, account_id, target);
create index ledger_user_target on public.ledger_entries (user_id, target);
create index ledger_entry on public.ledger_entries (entry_id);
create index ledger_user_account_replay on public.ledger_entries (user_id, account_id, occurred_on, seq);

-- Доступ: свои строки и только разрешённому (ADR-0007). С клиента всё это только читается,
-- пишут RPC ниже (security definer).
select public.apply_user_rls('public.user_settings');
select public.apply_user_rls('public.entries');
select public.apply_user_rls('public.ledger_entries');
revoke all on public.user_settings, public.entries, public.ledger_entries from authenticated;
grant select on public.user_settings, public.entries, public.ledger_entries to authenticated;

-- 5. Движок. Схема engine не публикуется PostgREST и закрыта от клиентов: её зовут только
-- публичные RPC. Интерфейс один: engine.recompute(user) — полный пересчёт пользователя.
--
-- Как добавить тип записи (тикеты 06–20): функция engine.apply_<тип>(st, e) и ветка в
-- engine.apply_entry. Движения пишутся только через engine.post (он же ведёт состояние),
-- проверки «до нуля» через engine.fail (код ошибки плюс id записи), предупреждения
-- в engine.collect_warnings.

create schema engine;
revoke all on schema engine from public;

-- Состояние реплея на момент текущей записи.
create type engine.replay_state as (
  bal      jsonb,   -- account_id -> остаток в валюте счёта
  adv      jsonb,   -- account_id -> аванс в тиынах
  owe_me   bigint,  -- «компания должна мне»
  i_owe    bigint,  -- «я должен компании»
  splits   jsonb,   -- entry_id -> сплит траты, для возврата покупки (тикет 13)
  warnings jsonb    -- предупреждения пересчёта, массив объектов {code, entry_id, ...}
);

-- Ошибка операции: message = код из дока 05, detail = JSON с подробностями.
create function engine.raise_error(p_code text, p_info jsonb default '{}') returns void
language plpgsql as $$
begin
  raise exception using message = p_code, detail = p_info::text, errcode = 'P0001';
end $$;

-- Нарушение правила на конкретной записи (ADR-0006): код и id записи, транзакция откатывается.
create function engine.fail(p_code text, e public.entries, p_info jsonb default '{}') returns void
language plpgsql as $$
begin
  perform engine.raise_error(p_code,
    jsonb_build_object('entry_id', e.id, 'occurred_on', e.occurred_on) || p_info);
end $$;

create function engine.balance_of(st engine.replay_state, p_account uuid) returns bigint
language sql immutable as $$ select coalesce((st.bal ->> p_account::text)::bigint, 0) $$;

create function engine.advance_of(st engine.replay_state, p_account uuid) returns bigint
language sql immutable as $$ select coalesce((st.adv ->> p_account::text)::bigint, 0) $$;

create function engine.debt_of(st engine.replay_state, p_side public.ledger_target) returns bigint
language sql immutable as $$
  select case p_side when 'company_owes_me' then st.owe_me when 'i_owe_company' then st.i_owe end
$$;

-- Единственное место, где пишется журнал: строка движения плюс тот же сдвиг в состоянии.
create function engine.post(st engine.replay_state, e public.entries,
                            p_target public.ledger_target, p_account uuid, p_delta bigint)
returns engine.replay_state
language plpgsql as $$
begin
  if p_delta = 0 then
    return st;
  end if;
  insert into public.ledger_entries (user_id, entry_id, account_id, target, delta_minor, occurred_on, seq)
  values (e.user_id, e.id, p_account, p_target, p_delta, e.occurred_on, e.seq);
  case p_target
    when 'balance' then
      st.bal := st.bal || jsonb_build_object(p_account, engine.balance_of(st, p_account) + p_delta);
    when 'card_advance' then
      st.adv := st.adv || jsonb_build_object(p_account, engine.advance_of(st, p_account) + p_delta);
    when 'company_owes_me' then
      st.owe_me := st.owe_me + p_delta;
    when 'i_owe_company' then
      st.i_owe := st.i_owe + p_delta;
  end case;
  return st;
end $$;

-- Корректировка (док 03, 4.7). Пока только долговая цель: стартовый долг и сверка (ADR-0008).
-- Цель «остаток» (с авансом) добавляет тикет 06.
create function engine.apply_adjustment(st engine.replay_state, e public.entries)
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
    else
      perform engine.fail('entry_type_not_supported', e,
        jsonb_build_object('type', e.type, 'adjustment_target', e.adjustment_target));
  end case;
  return st;
end $$;

-- Единая точка разбора по типу записи.
create function engine.apply_entry(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
begin
  case e.type
    when 'adjustment' then return engine.apply_adjustment(st, e);
    else
      perform engine.fail('entry_type_not_supported', e, jsonb_build_object('type', e.type));
  end case;
  return st;
end $$;

-- Предупреждения по состоянию после записи. Не блокируют запись, уходят в ответ пересчёта.
-- Тикет 07 добавляет сюда «остаток счёта в минусе».
create function engine.collect_warnings(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
begin
  return st;
end $$;

-- Полный пересчёт пользователя (док 03, раздел 7): журнал собирается заново из учтённых
-- записей в хронологическом порядке. Черновики не входят. Возвращает { warnings }.
create function engine.recompute(p_user uuid) returns jsonb
language plpgsql as $$
declare
  st engine.replay_state := row('{}', '{}', 0, 0, '{}', '[]')::engine.replay_state;
  e  public.entries;
begin
  -- Два пересчёта одного пользователя не должны перемешать журнал.
  perform pg_advisory_xact_lock(hashtextextended('engine.recompute:' || p_user::text, 0));
  delete from public.ledger_entries where user_id = p_user;

  for e in
    select * from public.entries
    where user_id = p_user and status = 'done'
    order by occurred_on, occurred_at nulls last, created_at, seq
  loop
    st := engine.apply_entry(st, e);
    st := engine.collect_warnings(st, e);
  end loop;

  return jsonb_build_object('warnings', st.warnings);
end $$;

revoke all on all functions in schema engine from public;

-- 6. Публичные RPC.

-- Служебный полный пересчёт текущего пользователя.
create function public.recompute() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.assert_allowed();
  return jsonb_build_object('ok', true) || engine.recompute(auth.uid());
end $$;

revoke all on function public.recompute() from public, anon;
grant execute on function public.recompute() to authenticated;

-- Первый запуск (ADR-0008, док 05): фиксирует дату начала учёта (по умолчанию сегодня по
-- Алматы) и заводит стартовый долг долговыми корректировками на эту дату. Один раз.
create function public.setup_start(
  p_accounting_start_date date default null,
  p_company_owes_me_minor bigint default 0,
  p_i_owe_company_minor   bigint default 0
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_date   date := coalesce(p_accounting_start_date, (now() at time zone 'Asia/Almaty')::date);
  v_side   record;
  v_result jsonb;
begin
  perform public.assert_allowed();
  if p_company_owes_me_minor is null or p_i_owe_company_minor is null then
    perform engine.raise_error('missing_required');
  end if;
  if p_company_owes_me_minor < 0 or p_i_owe_company_minor < 0 then
    perform engine.raise_error('amount_negative');
  end if;

  insert into public.user_settings (user_id, accounting_start_date)
  values (v_uid, v_date)
  on conflict (user_id) do nothing;
  if not found then
    perform engine.raise_error('start_already_set');
  end if;

  for v_side in
    select * from (values ('company_owes_me'::public.adjustment_target, p_company_owes_me_minor),
                          ('i_owe_company'::public.adjustment_target, p_i_owe_company_minor)) s (target, amount)
    where amount > 0
  loop
    insert into public.entries (user_id, type, occurred_on, amount_minor, currency, amount_kzt_minor,
                                adjustment_mode, adjustment_sign, adjustment_target, in_analytics, title)
    values (v_uid, 'adjustment', v_date, v_side.amount, 'KZT', v_side.amount,
            'plug_hidden', 1, v_side.target, false, 'Стартовый долг');
  end loop;

  v_result := engine.recompute(v_uid);
  return jsonb_build_object('ok', true) || v_result;
end $$;

revoke all on function public.setup_start(date, bigint, bigint) from public, anon;
grant execute on function public.setup_start(date, bigint, bigint) to authenticated;

-- 7. Выборка «Расчёт с компанией»: обе стороны долга и итог, только из журнала.
create view public.v_company_settlement with (security_invoker = true) as
select owe_me as company_owes_me_minor,
       i_owe  as i_owe_company_minor,
       owe_me - i_owe as net_minor
from (
  select coalesce(sum(delta_minor) filter (where target = 'company_owes_me'), 0)::bigint as owe_me,
         coalesce(sum(delta_minor) filter (where target = 'i_owe_company'), 0)::bigint   as i_owe
  from public.ledger_entries
  where user_id = (select auth.uid()) and target in ('company_owes_me', 'i_owe_company')
) sides;

revoke all on public.v_company_settlement from anon, authenticated;
grant select on public.v_company_settlement to authenticated;
