-- Тикет 09: пополнение от компании и изъятие аванса (док 03, 4.3 и 4.4; ADR-0003, ADR-0006).
-- Расширяет общий путь записи тикета 07: ветки company_topup и company_advance_return в
-- engine.check_entry и engine.apply_entry (обе функции скопированы с последнего определения
-- в 20261107120000_expense_and_income.sql, прежние ветки сохранены).

-- 1. Проверка записей.

-- Комиссия пополнения: не меньше нуля; при комиссии нужен плательщик, без неё плательщика нет.
-- Пришло на счёт = сумма минус комиссия, если комиссию платил я (банк удержал её из суммы,
-- компания засчитывает всю сумму), иначе сама сумма. Пришло должно быть больше нуля.
create function engine.check_company_topup(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a public.accounts;
begin
  a := engine.check_entry_account(n, e.account_id, 'account_id');
  n.account_id := a.id;
  n := engine.check_entry_currency(n, a);
  if e.fee_minor < 0 then
    perform engine.raise_error('amount_negative', '{"field": "fee_minor"}');
  end if;
  n.fee_minor := e.fee_minor;
  if n.fee_minor > 0 then
    if e.fee_payer is null then
      perform engine.raise_error('missing_required', '{"field": "fee_payer"}');
    end if;
    n.fee_payer := e.fee_payer;
    if n.fee_payer = 'own' and n.fee_minor >= n.amount_minor then
      perform engine.raise_error('fee_too_big', jsonb_build_object(
        'amount_minor', n.amount_minor, 'fee_minor', n.fee_minor));
    end if;
  end if;
  return n;
end $$;

-- Изъятие аванса: только счёт. «Не больше аванса на эту дату» проверяет пересчёт (ADR-0006).
create function engine.check_company_advance_return(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a public.accounts;
begin
  a := engine.check_entry_account(n, e.account_id, 'account_id');
  n.account_id := a.id;
  n := engine.check_entry_currency(n, a);
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
    when 'company_topup'          then n := engine.check_company_topup(n, e);
    when 'company_advance_return' then n := engine.check_company_advance_return(n, e);
    else
      perform engine.raise_error('entry_type_not_supported', jsonb_build_object('type', e.type));
  end case;

  n.fingerprint := engine.fingerprint(n);
  return n;
end $$;

-- 2. Движок.

-- Пополнение от компании (док 03, 4.3). Без комиссии или комиссию платила компания: остаток и
-- аванс плюс сумма. Комиссию платил я (ADR-0003): остаток плюс сумма минус комиссия; комиссия
-- сначала из своих денег на счёте до операции, нехватку съедает аванс; моя часть возмещается:
-- сначала гасит «я должен компании», остаток идёт в «компания должна мне».
create function engine.apply_company_topup(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  v_own_avail bigint;
  v_own_part  bigint := 0;
  v_co_part   bigint := 0;
  v_offset    bigint := 0;
begin
  if e.fee_payer = 'own' and e.fee_minor > 0 then
    v_own_avail := greatest(0, engine.balance_of(st, e.account_id) - engine.advance_of(st, e.account_id));
    v_own_part := least(e.fee_minor, v_own_avail);
    v_co_part := e.fee_minor - v_own_part;
    v_offset := least(v_own_part, st.i_owe);
    st := engine.post(st, e, 'balance', e.account_id, engine.balance_amount(e, e.account_id) - e.fee_minor);
  else
    st := engine.post(st, e, 'balance', e.account_id, engine.balance_amount(e, e.account_id));
  end if;
  st := engine.post(st, e, 'card_advance', e.account_id, e.amount_kzt_minor - v_co_part);
  st := engine.post(st, e, 'i_owe_company', null, -v_offset);
  st := engine.post(st, e, 'company_owes_me', null, v_own_part - v_offset);
  return st;
end $$;

-- Изъятие аванса (док 03, 4.4): аванс и остаток минус сумма, долг не меняется. Изъять больше
-- аванса на момент записи нельзя (ADR-0006): ошибка указывает эту запись, всё откатывается.
create function engine.apply_company_advance_return(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  v_adv bigint := engine.advance_of(st, e.account_id);
begin
  if e.amount_kzt_minor > v_adv then
    perform engine.fail('advance_return_too_big', e, jsonb_build_object(
      'account_id', e.account_id, 'advance_minor', v_adv, 'amount_minor', e.amount_kzt_minor));
  end if;
  st := engine.post(st, e, 'balance', e.account_id, -engine.balance_amount(e, e.account_id));
  return engine.post(st, e, 'card_advance', e.account_id, -e.amount_kzt_minor);
end $$;

create or replace function engine.apply_entry(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
begin
  case e.type
    when 'adjustment'             then return engine.apply_adjustment(st, e);
    when 'expense'                then return engine.apply_expense(st, e);
    when 'income'                 then return engine.apply_income(st, e);
    when 'company_topup'          then return engine.apply_company_topup(st, e);
    when 'company_advance_return' then return engine.apply_company_advance_return(st, e);
    else
      perform engine.fail('entry_type_not_supported', e, jsonb_build_object('type', e.type));
  end case;
  return st;
end $$;

-- 3. Суммы пополнения для формы: три способа ввода комиссии (док 03, 4.3, «UI вычисляет landed
-- из трёх стилей ввода»; считает сервер, клиент не вычитает). Банк удерживает комиссию из
-- отправленного: пришло = отправила − комиссия. Сумма записи (amount_minor) = сколько компания
-- засчитывает как аванс: всё отправленное, если комиссию плачу я, иначе то, что пришло.
--   sent_fee      — p_first = отправила компания, p_second = комиссия;
--   arrived_fee   — p_first = пришло на счёт,     p_second = комиссия;
--   sent_arrived  — p_first = отправила компания, p_second = пришло на счёт.
create function public.topup_amounts(p_style text, p_first_minor bigint, p_second_minor bigint,
                                     p_fee_payer public.fee_payer default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_sent    bigint;
  v_arrived bigint;
  v_fee     bigint;
begin
  perform public.assert_allowed();
  if p_first_minor is null or p_second_minor is null then
    perform engine.raise_error('missing_required', jsonb_build_object(
      'field', case when p_first_minor is null then 'first_minor' else 'second_minor' end));
  end if;
  if p_first_minor < 0 or p_second_minor < 0 then
    perform engine.raise_error('amount_negative');
  end if;
  case p_style
    when 'sent_fee'     then v_sent := p_first_minor; v_fee := p_second_minor; v_arrived := v_sent - v_fee;
    when 'arrived_fee'  then v_arrived := p_first_minor; v_fee := p_second_minor; v_sent := v_arrived + v_fee;
    when 'sent_arrived' then v_sent := p_first_minor; v_arrived := p_second_minor; v_fee := v_sent - v_arrived;
    else perform engine.raise_error('field_invalid', '{"field": "style"}');
  end case;
  if v_arrived <= 0 or v_fee < 0 then
    perform engine.raise_error('fee_too_big', jsonb_build_object('sent_minor', v_sent, 'arrived_minor', v_arrived));
  end if;
  -- Пока при комиссии не выбран плательщик, сумма записи неизвестна: форма спрашивает его.
  return jsonb_build_object(
    'sent_minor', v_sent, 'arrived_minor', v_arrived, 'fee_minor', v_fee,
    'fee_payer_needed', v_fee > 0,
    'fee_payer', case when v_fee > 0 then p_fee_payer end,
    'amount_minor', case when v_fee = 0 then v_arrived
                         when p_fee_payer = 'own' then v_sent
                         when p_fee_payer = 'company' then v_arrived end);
end $$;

-- Аванс счёта на дату для формы изъятия («изъять можно не больше»). p_entry_id при правке:
-- место записи в хронологии остаётся её. Окончательно проверяет пересчёт.
create function public.advance_on_date(p_account_id uuid, p_occurred_on date, p_entry_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  a public.accounts;
  e public.entries;
begin
  perform public.assert_allowed();
  a := engine.own_account(auth.uid(), p_account_id);
  if p_entry_id is not null then
    e := engine.own_entry(auth.uid(), p_entry_id);
  else
    e.user_id := auth.uid();
    e.created_at := now();
  end if;
  e.occurred_on := p_occurred_on;
  return jsonb_build_object('advance_minor', engine.advance_before(e, a.id));
end $$;

revoke all on function public.advance_on_date(uuid, date, uuid) from public, anon;
grant execute on function public.advance_on_date(uuid, date, uuid) to authenticated;

revoke all on function public.topup_amounts(text, bigint, bigint, public.fee_payer) from public, anon;
grant execute on function public.topup_amounts(text, bigint, bigint, public.fee_payer) to authenticated;

-- 4. Лента: комиссия и плательщик нужны форме правки пополнения (новые колонки в конце).
create or replace view public.v_entries with (security_invoker = true) as
select e.id as entry_id, e.type, e.status, e.occurred_on, e.occurred_at, e.amount_minor, e.currency,
       e.account_id, a.name as account_name, e.to_account_id, e.category_id, c.name as category_name,
       e.purpose, e.source, e.in_analytics, e.comment, e.title, e.created_at, e.seq,
       coalesce(l.balance, 0)::bigint as balance_delta_minor,
       coalesce(l.advance, 0)::bigint as advance_delta_minor,
       coalesce(l.owe_me, 0)::bigint  as company_owes_me_delta_minor,
       coalesce(l.i_owe, 0)::bigint   as i_owe_company_delta_minor,
       e.fee_minor, e.fee_payer
from public.entries e
left join public.accounts a on a.id = e.account_id
left join public.categories c on c.id = e.category_id
left join (
  select entry_id,
         sum(delta_minor) filter (where target = 'balance')         as balance,
         sum(delta_minor) filter (where target = 'card_advance')    as advance,
         sum(delta_minor) filter (where target = 'company_owes_me') as owe_me,
         sum(delta_minor) filter (where target = 'i_owe_company')   as i_owe
  from public.ledger_entries
  where user_id = (select auth.uid())
  group by entry_id
) l on l.entry_id = e.id
where e.user_id = (select auth.uid());

revoke all on public.v_entries from anon, authenticated;
grant select on public.v_entries to authenticated;

revoke all on all functions in schema engine from public;
