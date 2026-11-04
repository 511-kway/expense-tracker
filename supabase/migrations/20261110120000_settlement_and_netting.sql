-- Тикет 11: погашение долга и взаимозачёт (док 03, 4.6 и 8; ADR-0006; spec.md: в погашении
-- долга счёт обязателен, деньги от компании приходят как свои; новый тип «взаимозачёт»).
-- Расширяет общий путь записи: ветки settlement и netting в engine.check_entry и
-- engine.apply_entry (обе скопированы с последнего определения в 20261109120000_transfers.sql,
-- прежние ветки сохранены).

-- 1. Проверка записи.

-- Погашение долга: счёт и направление обязательны. «Не больше стороны долга на дату»
-- проверяет пересчёт (ADR-0006).
create function engine.check_settlement(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a public.accounts;
begin
  a := engine.check_entry_account(n, e.account_id, 'account_id');
  n.account_id := a.id;
  n := engine.check_entry_currency(n, a);
  if e.settlement_direction is null then
    perform engine.raise_error('missing_required', '{"field": "settlement_direction"}');
  end if;
  n.settlement_direction := e.settlement_direction;
  return n;
end $$;

-- Взаимозачёт: денег не было, поэтому счёта нет (если пришёл, отбрасывается). Только тенге:
-- долг ведётся в тенге. «Не больше меньшей стороны на дату» проверяет пересчёт (ADR-0006).
create function engine.check_netting(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
begin
  n.currency := coalesce(n.currency, 'KZT');
  if n.currency <> 'KZT' then
    perform engine.raise_error('foreign_amount_not_supported', jsonb_build_object('currency', n.currency));
  end if;
  n.amount_kzt_minor := n.amount_minor;
  n.rate := null;
  n.rate_source := null;
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
    when 'settlement'             then n := engine.check_settlement(n, e);
    when 'netting'                then n := engine.check_netting(n, e);
    else
      perform engine.raise_error('entry_type_not_supported', jsonb_build_object('type', e.type));
  end case;

  n.fingerprint := engine.fingerprint(n);
  return n;
end $$;

-- 2. Движок.

-- Погашение долга (док 03, 4.6; spec.md): деньги прошли через счёт, нужная сторона долга
-- минус сумма. «Я отдал компании»: остаток минус, «я должен компании» минус. «Компания отдала
-- мне»: остаток плюс как свои деньги (аванс не меняется), «компания должна мне» минус. Не больше
-- стороны на момент записи (ADR-0006): debt_overpay указывает эту запись, всё откатывается.
create function engine.apply_settlement(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  k      bigint := e.amount_kzt_minor;
  v_side public.ledger_target;
  v_sign int;
begin
  if e.settlement_direction = 'i_paid_company' then
    v_side := 'i_owe_company'; v_sign := -1;
  else
    v_side := 'company_owes_me'; v_sign := 1;
  end if;
  if k > engine.debt_of(st, v_side) then
    perform engine.fail('debt_overpay', e, jsonb_build_object(
      'side', v_side, 'available_minor', engine.debt_of(st, v_side), 'amount_minor', k));
  end if;
  st := engine.post(st, e, 'balance', e.account_id, v_sign * engine.balance_amount(e, e.account_id));
  return engine.post(st, e, v_side, null, -k);
end $$;

-- Взаимозачёт (spec.md): обе стороны долга минус одна сумма, остатки и авансы не меняются.
-- Не больше меньшей стороны на момент записи (ADR-0006): netting_too_big указывает эту запись
-- и обе стороны на тот момент, всё откатывается.
create function engine.apply_netting(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  k bigint := e.amount_kzt_minor;
begin
  if k > least(st.owe_me, st.i_owe) then
    perform engine.fail('netting_too_big', e, jsonb_build_object(
      'available_minor', least(st.owe_me, st.i_owe), 'company_owes_me_minor', st.owe_me,
      'i_owe_company_minor', st.i_owe, 'amount_minor', k));
  end if;
  st := engine.post(st, e, 'company_owes_me', null, -k);
  return engine.post(st, e, 'i_owe_company', null, -k);
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
    when 'settlement'             then return engine.apply_settlement(st, e);
    when 'netting'                then return engine.apply_netting(st, e);
    else
      perform engine.fail('entry_type_not_supported', e, jsonb_build_object('type', e.type));
  end case;
  return st;
end $$;

-- 3. Лента: направление погашения долга (новая колонка в конце, как требует create or replace view).
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
       coalesce(l.to_advance, 0)::bigint as to_advance_delta_minor,
       e.settlement_direction
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

-- 4. Разбор долга (док 05, v_settlement_breakdown): записи, из которых сложилась каждая сторона
-- долга, по журналу последнего пересчёта. Строка = запись × сторона: дельта записи по этой
-- стороне и сторона после неё (в порядке пересчёта). Сюда попадает всё, что двигает долг:
-- стартовый долг и долговые корректировки, траты, возмещение комиссии пополнения, переводы
-- «погашение долга в аванс» и «взял из аванса себе», погашения долга и взаимозачёты.
create view public.v_settlement_breakdown with (security_invoker = true) as
select d.entry_id, d.side, e.type, e.occurred_on, e.occurred_at, e.created_at, e.seq,
       e.title, c.name as category_name, e.account_id, a.name as account_name, t.name as to_account_name,
       e.purpose, e.source, e.transfer_purpose, e.settlement_direction, e.amount_minor, e.currency,
       d.delta_minor,
       (sum(d.delta_minor) over (partition by d.side
          order by e.occurred_on, e.occurred_at nulls last, e.created_at, e.seq))::bigint as side_after_minor
from (
  select l.entry_id, l.target as side, sum(l.delta_minor)::bigint as delta_minor
  from public.ledger_entries l
  where l.user_id = (select auth.uid()) and l.target in ('company_owes_me', 'i_owe_company')
  group by l.entry_id, l.target
) d
join public.entries e on e.id = d.entry_id
left join public.accounts a on a.id = e.account_id
left join public.accounts t on t.id = e.to_account_id
left join public.categories c on c.id = e.category_id;

revoke all on public.v_settlement_breakdown from anon, authenticated;
grant select on public.v_settlement_breakdown to authenticated;

revoke all on all functions in schema engine from public;
