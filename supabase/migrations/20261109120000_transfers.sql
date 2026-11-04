-- Тикет 10: переводы между своими счетами (док 03, 4.5 и 8; ADR-0006; spec.md: назначения
-- «перевод своих», «перекладка аванса», «погашение долга в аванс», «взял из аванса себе»,
-- без «пополнил аванс переводом»). Расширяет общий путь записи: ветка transfer в
-- engine.check_entry и engine.apply_entry (обе скопированы с последнего определения в
-- 20261108120000_company_topup.sql, прежние ветки сохранены).

-- 1. Проверка записи.

-- Перевод: «откуда» и «куда» свои, разные, одной валюты; дата не раньше старта обоих счетов;
-- назначение обязательно. Комиссия как у пополнения: не меньше нуля, при комиссии нужен
-- плательщик, без неё плательщика нет. «Погашение долга в аванс не больше долга» проверяет
-- пересчёт (ADR-0006).
create function engine.check_transfer(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a  public.accounts;
  b  public.accounts;
begin
  if e.account_id is null then
    perform engine.raise_error('missing_required', '{"field": "account_id"}');
  end if;
  if e.to_account_id is null then
    perform engine.raise_error('missing_required', '{"field": "to_account_id"}');
  end if;
  if e.account_id = e.to_account_id then
    perform engine.raise_error('same_account_transfer', jsonb_build_object('account_id', e.account_id));
  end if;
  a := engine.check_entry_account(n, e.account_id, 'account_id');
  b := engine.check_entry_account(n, e.to_account_id, 'to_account_id');
  if a.currency <> b.currency then
    perform engine.raise_error('cross_currency_transfer', jsonb_build_object(
      'account_id', a.id, 'currency', a.currency, 'to_account_id', b.id, 'to_currency', b.currency));
  end if;
  n.account_id := a.id;
  n.to_account_id := b.id;
  n := engine.check_entry_currency(n, a);
  if e.transfer_purpose is null then
    perform engine.raise_error('missing_required', '{"field": "transfer_purpose"}');
  end if;
  n.transfer_purpose := e.transfer_purpose;
  if e.fee_minor < 0 then
    perform engine.raise_error('amount_negative', '{"field": "fee_minor"}');
  end if;
  n.fee_minor := e.fee_minor;
  if n.fee_minor > 0 then
    if e.fee_payer is null then
      perform engine.raise_error('missing_required', '{"field": "fee_payer"}');
    end if;
    n.fee_payer := e.fee_payer;
  end if;
  return n;
end $$;

create or replace function engine.check_entry(e public.entries) returns public.entries
language plpgsql stable as $$
declare
  n       public.entries;
  v_start date;
begin
  if e.type is null then
    perform engine.raise_error('missing_required', '{"field": "type"}');
  end if;
  if e.status <> 'done' then
    -- Черновики появятся с быстрым вводом (тикет 15).
    perform engine.raise_error('entry_status_not_supported', jsonb_build_object('status', e.status));
  end if;
  if e.occurred_on is null then
    perform engine.raise_error('missing_required', '{"field": "occurred_on"}');
  end if;
  if e.amount_minor is null then
    perform engine.raise_error('missing_required', '{"field": "amount_minor"}');
  end if;
  if e.amount_minor <= 0 then
    perform engine.raise_error('amount_not_positive');
  end if;
  select accounting_start_date into v_start from public.user_settings where user_id = e.user_id;
  if v_start is null then
    perform engine.raise_error('start_not_set');
  end if;
  if e.occurred_on < v_start then
    perform engine.raise_error('entry_before_start', jsonb_build_object(
      'occurred_on', e.occurred_on, 'accounting_start_date', v_start));
  end if;

  -- Общие поля; поля типа переносит его проверка.
  n.id := e.id; n.user_id := e.user_id; n.created_at := e.created_at; n.seq := e.seq;
  n.type := e.type; n.status := e.status;
  n.occurred_on := e.occurred_on; n.occurred_at := e.occurred_at;
  n.amount_minor := e.amount_minor; n.currency := e.currency; n.amount_kzt_minor := e.amount_kzt_minor;
  n.rate := e.rate; n.rate_source := e.rate_source;
  n.source_pending := false; n.fee_minor := 0; n.adjustment_affects_advance := false;
  n.in_analytics := e.in_analytics;
  n.comment := e.comment; n.title := e.title;
  n.source_note_id := e.source_note_id; n.external_id := e.external_id;

  case e.type
    when 'expense'                then n := engine.check_expense(n, e);
    when 'income'                 then n := engine.check_income(n, e);
    when 'transfer'               then n := engine.check_transfer(n, e);
    when 'company_topup'          then n := engine.check_company_topup(n, e);
    when 'company_advance_return' then n := engine.check_company_advance_return(n, e);
    else
      perform engine.raise_error('entry_type_not_supported', jsonb_build_object('type', e.type));
  end case;

  n.fingerprint := engine.fingerprint(n);
  return n;
end $$;

-- 2. Движок.

-- Перевод (док 03, 4.5): остаток «откуда» минус сумма, «куда» плюс сумма. Комиссия по
-- плательщику: компания съедает аванс, я трачу только остаток; она идёт раньше назначения,
-- поэтому перекладка аванса переносит то, что осталось после комиссии. Дальше по назначению:
--   move_own      перевод своих: больше ничего;
--   move_company  перекладка аванса: аванс переезжает, сколько есть на «откуда», остальное свои;
--   take_advance  взял из аванса себе: аванс «откуда» минус, сколько есть, и столько же
--                 в «я должен компании»; остальное свои;
--   repay_debt    погашение долга в аванс: мои деньги становятся авансом «куда» и гасят
--                 «я должен компании». Не больше долга на момент записи (ADR-0006): ошибка
--                 debt_overpay указывает эту запись, всё откатывается.
create function engine.apply_transfer(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  k         bigint := e.amount_kzt_minor;
  v_company bigint;
begin
  st := engine.post(st, e, 'balance', e.account_id, -engine.balance_amount(e, e.account_id));
  st := engine.post(st, e, 'balance', e.to_account_id, engine.balance_amount(e, e.to_account_id));
  -- Комиссия всегда с «откуда»; если платит компания, она съедает аванс (сколько есть).
  -- Переводы пока только в тенге (тикет 14), поэтому комиссия в тиынах и для аванса.
  st := engine.post(st, e, 'balance', e.account_id, -e.fee_minor);
  if e.fee_payer = 'company' then
    st := engine.post(st, e, 'card_advance', e.account_id, -least(e.fee_minor, engine.advance_of(st, e.account_id)));
  end if;
  case e.transfer_purpose
    when 'move_own' then
      null;
    when 'move_company' then
      v_company := least(k, engine.advance_of(st, e.account_id));
      st := engine.post(st, e, 'card_advance', e.account_id, -v_company);
      st := engine.post(st, e, 'card_advance', e.to_account_id, v_company);
    when 'repay_debt' then
      if k > st.i_owe then
        perform engine.fail('debt_overpay', e, jsonb_build_object(
          'side', 'i_owe_company', 'available_minor', st.i_owe, 'amount_minor', k));
      end if;
      st := engine.post(st, e, 'card_advance', e.to_account_id, k);
      st := engine.post(st, e, 'i_owe_company', null, -k);
    when 'take_advance' then
      v_company := least(k, engine.advance_of(st, e.account_id));
      st := engine.post(st, e, 'card_advance', e.account_id, -v_company);
      st := engine.post(st, e, 'i_owe_company', null, v_company);
  end case;
  return st;
end $$;

create or replace function engine.apply_entry(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
begin
  case e.type
    when 'adjustment'             then return engine.apply_adjustment(st, e);
    when 'expense'                then return engine.apply_expense(st, e);
    when 'income'                 then return engine.apply_income(st, e);
    when 'transfer'               then return engine.apply_transfer(st, e);
    when 'company_topup'          then return engine.apply_company_topup(st, e);
    when 'company_advance_return' then return engine.apply_company_advance_return(st, e);
    else
      perform engine.fail('entry_type_not_supported', e, jsonb_build_object('type', e.type));
  end case;
  return st;
end $$;

-- 3. Обе стороны долга на дату для формы погашения долга в аванс («не больше моего долга»).
-- Как advance_on_date: по журналу последнего пересчёта, на момент перед записью; p_entry_id
-- при правке, место записи в хронологии остаётся её. Окончательно проверяет пересчёт.
create function engine.debt_before(e public.entries, p_side public.ledger_target) returns bigint
language sql stable as $$
  select coalesce(sum(l.delta_minor), 0)::bigint
  from public.ledger_entries l
  join public.entries x on x.id = l.entry_id
  where l.user_id = e.user_id and l.target = p_side
    and x.id is distinct from e.id
    and (x.occurred_on, coalesce(x.occurred_at, 'infinity'), x.created_at, x.seq)
      < (e.occurred_on, coalesce(e.occurred_at, 'infinity'), e.created_at, coalesce(e.seq, 9223372036854775807))
$$;

create function public.debt_on_date(p_occurred_on date, p_entry_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  e public.entries;
begin
  perform public.assert_allowed();
  if p_entry_id is not null then
    e := engine.own_entry(auth.uid(), p_entry_id);
  else
    e.user_id := auth.uid();
    e.created_at := now();
  end if;
  e.occurred_on := p_occurred_on;
  return jsonb_build_object(
    'company_owes_me_minor', engine.debt_before(e, 'company_owes_me'),
    'i_owe_company_minor', engine.debt_before(e, 'i_owe_company'));
end $$;

revoke all on function public.debt_on_date(date, uuid) from public, anon;
grant execute on function public.debt_on_date(date, uuid) to authenticated;

-- 4. Лента: перевод трогает два счёта. Дельты остатка и аванса теперь по «откуда» (у записей
-- на одном счёте это все их движения), рядом «куда»: название и его дельты. Новые колонки
-- в конце, как требует create or replace view.
create or replace view public.v_entries with (security_invoker = true) as
select e.id as entry_id, e.type, e.status, e.occurred_on, e.occurred_at, e.amount_minor, e.currency,
       e.account_id, a.name as account_name, e.to_account_id, e.category_id, c.name as category_name,
       e.purpose, e.source, e.in_analytics, e.comment, e.title, e.created_at, e.seq,
       coalesce(l.balance, 0)::bigint as balance_delta_minor,
       coalesce(l.advance, 0)::bigint as advance_delta_minor,
       coalesce(l.owe_me, 0)::bigint  as company_owes_me_delta_minor,
       coalesce(l.i_owe, 0)::bigint   as i_owe_company_delta_minor,
       e.fee_minor, e.fee_payer,
       e.transfer_purpose, t.name as to_account_name,
       coalesce(l.to_balance, 0)::bigint as to_balance_delta_minor,
       coalesce(l.to_advance, 0)::bigint as to_advance_delta_minor
from public.entries e
left join public.accounts a on a.id = e.account_id
left join public.accounts t on t.id = e.to_account_id
left join public.categories c on c.id = e.category_id
left join (
  select l.entry_id,
         sum(l.delta_minor) filter (where l.target = 'balance' and l.account_id = x.account_id)         as balance,
         sum(l.delta_minor) filter (where l.target = 'card_advance' and l.account_id = x.account_id)    as advance,
         sum(l.delta_minor) filter (where l.target = 'company_owes_me')                                  as owe_me,
         sum(l.delta_minor) filter (where l.target = 'i_owe_company')                                    as i_owe,
         sum(l.delta_minor) filter (where l.target = 'balance' and l.account_id = x.to_account_id)      as to_balance,
         sum(l.delta_minor) filter (where l.target = 'card_advance' and l.account_id = x.to_account_id) as to_advance
  from public.ledger_entries l
  join public.entries x on x.id = l.entry_id
  where l.user_id = (select auth.uid())
  group by l.entry_id
) l on l.entry_id = e.id
where e.user_id = (select auth.uid());

revoke all on public.v_entries from anon, authenticated;
grant select on public.v_entries to authenticated;

revoke all on all functions in schema engine from public;
