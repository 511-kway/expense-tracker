-- Тикет 12: корректировки (док 03, 4.7; ADR-0006, ADR-0008; spec.md). Движок уже применяет
-- корректировку (engine.apply_adjustment: долговая цель из тикета 05, цель «остаток» с авансом
-- из тикета 06); здесь её получает общий путь записи: engine.check_adjustment и ветка
-- adjustment в engine.check_entry (скопирована с последнего определения в
-- 20261110120000_settlement_and_netting.sql, прежние ветки сохранены).

-- 1. Проверка записи.

-- Корректировка: цель (по умолчанию остаток) и знак обязательны.
-- Остаток: счёт обязателен (дата не раньше старта счёта), режим обязателен: «скрыта»
-- (plug_hidden) не попадает в разрезы трат, «в разрезах трат» (plug_analytics) попадает;
-- «меняет аванс» по желанию (аванс при минусе режется на нуле в пересчёте).
-- Сторона долга: счёта нет (присланный отбрасывается), только тенге, всегда скрыта и вне разрезов
-- трат, аванс не трогает. «Сторона не уходит в минус» проверяет пересчёт (debt_below_zero).
create function engine.check_adjustment(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a public.accounts;
begin
  if e.adjustment_sign is null then
    perform engine.raise_error('missing_required', '{"field": "adjustment_sign"}');
  end if;
  if e.adjustment_sign not in (1, -1) then
    perform engine.raise_error('field_invalid', '{"field": "adjustment_sign"}');
  end if;
  n.adjustment_sign := e.adjustment_sign;
  n.adjustment_target := coalesce(e.adjustment_target, 'balance');

  if n.adjustment_target = 'balance' then
    a := engine.check_entry_account(n, e.account_id, 'account_id');
    n.account_id := a.id;
    n := engine.check_entry_currency(n, a);
    if e.adjustment_mode is null then
      perform engine.raise_error('missing_required', '{"field": "adjustment_mode"}');
    end if;
    n.adjustment_mode := e.adjustment_mode;
    n.adjustment_affects_advance := e.adjustment_affects_advance;
  else
    n.currency := coalesce(n.currency, 'KZT');
    if n.currency <> 'KZT' then
      perform engine.raise_error('foreign_amount_not_supported', jsonb_build_object('currency', n.currency));
    end if;
    n.amount_kzt_minor := n.amount_minor;
    n.rate := null;
    n.rate_source := null;
    n.adjustment_mode := 'plug_hidden';
  end if;
  n.in_analytics := n.adjustment_mode = 'plug_analytics';
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
    when 'adjustment'             then n := engine.check_adjustment(n, e);
    else
      perform engine.raise_error('entry_type_not_supported', jsonb_build_object('type', e.type));
  end case;

  n.fingerprint := engine.fingerprint(n);
  return n;
end $$;

-- 2. Движок: тело скопировано с 20261106120000_accounts.sql без изменений правил; ошибка
-- debt_below_zero получила amount_minor (как debt_overpay и netting_too_big), чтобы форма
-- отличала конфликт на самой записи от более поздней корректировки.
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
          jsonb_build_object('side', v_side, 'available_minor', engine.debt_of(st, v_side),
                             'amount_minor', e.amount_kzt_minor));
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

-- 3. Лента: поля корректировки, чтобы форма открыла её на правку (новые колонки в конце, как
-- требует create or replace view; скопировано с 20261110120000_settlement_and_netting.sql).
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
       e.settlement_direction,
       e.adjustment_target, e.adjustment_sign, e.adjustment_mode, e.adjustment_affects_advance
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
