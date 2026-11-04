-- Тикет 13: возврат покупки (док 03, 4.8 и 8; ADR-0006; spec.md). Возврат ссылается на трату
-- (parent_entry_id), приходит на её счёт и откатывает её эффект по накопленной сумме возвратов:
-- восстановлено_X = floor(X · R / сумма траты) − уже восстановлено, для частей траты «из аванса» и
-- «свои», поэтому полный возврат закрывает всё в ноль без потери тиынов.
-- engine.check_entry скопирована с 20261111120000_adjustments.sql, engine.apply_entry с
-- 20261110120000_settlement_and_netting.sql, engine.apply_expense с 20261107120000_expense_and_income.sql,
-- update_entry и delete_entry с 20261107120000_expense_and_income.sql, v_entries с
-- 20261111120000_adjustments.sql; прежние ветки и колонки на месте.

-- 1. Проверка записи.

-- Возврат покупки: трата обязательна, своя и учтённая; счёт, категория, назначение и источник
-- берутся у траты (присланные отбрасываются). Дата не раньше траты. «Не больше невозвращённого»
-- проверяет только пересчёт (refund_too_big), как и другие проверки «до нуля» (ADR-0006).
create function engine.check_refund(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  p public.entries;
  a public.accounts;
begin
  if e.parent_entry_id is null then
    perform engine.raise_error('missing_required', '{"field": "parent_entry_id"}');
  end if;
  p := engine.own_entry(n.user_id, e.parent_entry_id);
  if p.type <> 'expense' or p.status <> 'done' then
    perform engine.raise_error('refund_parent_not_expense', jsonb_build_object(
      'parent_entry_id', p.id, 'type', p.type, 'status', p.status));
  end if;
  a := engine.check_entry_account(n, p.account_id, 'account_id');
  n.account_id := a.id;
  n := engine.check_entry_currency(n, a);
  if n.occurred_on < p.occurred_on then
    perform engine.raise_error('refund_before_expense', jsonb_build_object(
      'occurred_on', n.occurred_on, 'parent_entry_id', p.id, 'parent_occurred_on', p.occurred_on));
  end if;
  n.parent_entry_id := p.id;
  n.category_id := p.category_id;
  n.purpose := p.purpose;
  n.source := p.source;
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
    when 'refund'                 then n := engine.check_refund(n, e);
    else
      perform engine.raise_error('entry_type_not_supported', jsonb_build_object('type', e.type));
  end case;

  n.fingerprint := engine.fingerprint(n);
  return n;
end $$;

-- 2. Движок.

-- Трата: правила тикета 07 без изменений. Сплит в состоянии пересчёта теперь хранит и то, что
-- нужно возврату: назначение, источник и сколько уже возвращено и восстановлено по частям.
create or replace function engine.apply_expense(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  k         bigint := e.amount_kzt_minor;
  v_company bigint := 0;
begin
  st := engine.post(st, e, 'balance', e.account_id, -engine.balance_amount(e, e.account_id));
  if e.purpose = 'work' or e.source = 'company' then
    v_company := least(k, engine.advance_of(st, e.account_id));
    st := engine.post(st, e, 'card_advance', e.account_id, -v_company);
    if e.purpose = 'work' then
      st := engine.post(st, e, 'company_owes_me', null, k - v_company);
    else
      st := engine.post(st, e, 'i_owe_company', null, v_company);
    end if;
  end if;
  st.splits := st.splits || jsonb_build_object(e.id, jsonb_build_object(
    'company_part', v_company, 'own_part', k - v_company,
    'purpose', e.purpose, 'source', e.source,
    'refunded', 0, 'restored_company', 0, 'restored_own', 0));
  return st;
end $$;

-- Уменьшить сторону долга на p_amount; то, что не помещается (сторона уже погашена или зачтена),
-- уходит в другую сторону: долг развернулся (решено при реализации тикета 13).
create function engine.reduce_debt(st engine.replay_state, e public.entries,
                                   p_side public.ledger_target, p_amount bigint)
returns engine.replay_state
language plpgsql as $$
declare
  v_take bigint := least(p_amount, engine.debt_of(st, p_side));
begin
  st := engine.post(st, e, p_side, null, -v_take);
  return engine.post(st, e,
    case p_side when 'company_owes_me' then 'i_owe_company' else 'company_owes_me' end::public.ledger_target,
    null, p_amount - v_take);
end $$;

-- Возврат покупки (док 03, 4.8): остаток счёта плюс сумма; часть траты из аванса и своя часть
-- восстанавливаются по накопленной сумме возвратов R (включая этот):
-- restored_X = floor(X · R / сумма траты) − уже восстановлено.
-- Работа: аванс плюс восстановленная часть компании, «компания должна мне» минус восстановленная своя.
-- Личное деньгами компании: аванс и «я должен компании» на восстановленную часть компании.
-- Личное своими: только остаток. Трата должна быть раньше в порядке пересчёта; сумма всех
-- возвратов на момент этого не больше суммы траты (refund_too_big).
create function engine.apply_refund(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  s          jsonb := st.splits -> e.parent_entry_id::text;
  k          bigint := e.amount_kzt_minor;
  v_company  bigint;
  v_own      bigint;
  v_total    bigint;
  v_refunded bigint;
  v_r        bigint;
  v_rc       bigint;
  v_ro       bigint;
begin
  if s is null then
    perform engine.fail('refund_before_expense', e, jsonb_build_object('parent_entry_id', e.parent_entry_id));
  end if;
  v_company  := (s ->> 'company_part')::bigint;
  v_own      := (s ->> 'own_part')::bigint;
  v_total    := v_company + v_own;
  v_refunded := (s ->> 'refunded')::bigint;
  if v_refunded + k > v_total then
    perform engine.fail('refund_too_big', e, jsonb_build_object(
      'parent_entry_id', e.parent_entry_id, 'available_minor', v_total - v_refunded, 'amount_minor', k));
  end if;
  v_r  := v_refunded + k;
  -- numeric: произведение двух сумм может не поместиться в bigint.
  v_rc := floor(v_company::numeric * v_r / v_total)::bigint - (s ->> 'restored_company')::bigint;
  v_ro := floor(v_own::numeric * v_r / v_total)::bigint - (s ->> 'restored_own')::bigint;

  st := engine.post(st, e, 'balance', e.account_id, engine.balance_amount(e, e.account_id));
  st := engine.post(st, e, 'card_advance', e.account_id, v_rc);
  if s ->> 'purpose' = 'work' then
    st := engine.reduce_debt(st, e, 'company_owes_me', v_ro);
  elsif s ->> 'source' = 'company' then
    st := engine.reduce_debt(st, e, 'i_owe_company', v_rc);
  end if;

  st.splits := st.splits || jsonb_build_object(e.parent_entry_id, s || jsonb_build_object(
    'refunded', v_r,
    'restored_company', (s ->> 'restored_company')::bigint + v_rc,
    'restored_own', (s ->> 'restored_own')::bigint + v_ro));
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
    when 'settlement'             then return engine.apply_settlement(st, e);
    when 'netting'                then return engine.apply_netting(st, e);
    when 'refund'                 then return engine.apply_refund(st, e);
    else
      perform engine.fail('entry_type_not_supported', e, jsonb_build_object('type', e.type));
  end case;
  return st;
end $$;

-- 3. Трата с возвратами (решено при реализации тикета 13): удалить её или сменить ей тип нельзя,
-- пока есть возвраты (expense_has_refunds): возврат это реальные деньги на счёте, молча стирать его
-- нельзя, сначала удаляются возвраты. Правка траты разрешена: возвраты следуют за её счётом,
-- категорией и назначением, а пересчёт ловит сумму меньше возвращённого (refund_too_big)
-- и перенос траты позже возврата (refund_before_expense).

create function engine.assert_no_refunds(e public.entries) returns void
language plpgsql stable as $$
declare
  v_count bigint;
begin
  select count(*) into v_count from public.entries where parent_entry_id = e.id;
  if v_count > 0 then
    perform engine.raise_error('expense_has_refunds',
      jsonb_build_object('entry_id', e.id, 'refund_count', v_count));
  end if;
end $$;

-- Возвраты траты берут счёт, категорию, назначение и источник у неё (отпечаток пересчитывается).
create function engine.sync_refunds(p public.entries) returns void
language plpgsql as $$
declare
  r public.entries;
begin
  for r in select * from public.entries where parent_entry_id = p.id loop
    r.account_id := p.account_id;
    r.category_id := p.category_id;
    r.purpose := p.purpose;
    r.source := p.source;
    r.fingerprint := engine.fingerprint(r);
    update public.entries set account_id = r.account_id, category_id = r.category_id, purpose = r.purpose,
      source = r.source, fingerprint = r.fingerprint, updated_at = now()
    where id = r.id;
  end loop;
end $$;

create or replace function public.update_entry(p_entry_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  prior public.entries;
  e     public.entries;
begin
  perform public.assert_allowed();
  prior := engine.own_entry(auth.uid(), p_entry_id);
  e := engine.entry_from_payload(prior.user_id, p_payload);
  e.id := prior.id;
  e.created_at := prior.created_at;
  e.seq := prior.seq;
  if e.type is distinct from 'expense' then
    perform engine.assert_no_refunds(prior);
  end if;
  e := engine.replace_entry(engine.check_entry(e));
  if e.type = 'expense' then
    perform engine.sync_refunds(e);
  end if;
  return jsonb_build_object('ok', true, 'entry_id', e.id, 'status', e.status)
      || jsonb_build_object('warnings', engine.duplicate_warnings(e) || (engine.recompute(e.user_id) -> 'warnings'));
end $$;

create or replace function public.delete_entry(p_entry_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.entries;
begin
  perform public.assert_allowed();
  e := engine.own_entry(auth.uid(), p_entry_id);
  perform engine.assert_no_refunds(e);
  delete from public.entries where id = e.id;
  return jsonb_build_object('ok', true) || engine.recompute(e.user_id);
end $$;

-- 4. Сколько ещё можно вернуть по трате (для формы): сумма траты минус все её учтённые возвраты,
-- кроме p_entry_id (правка возврата). Клиент сам не вычитает.
create function public.refund_remaining(p_parent_entry_id uuid, p_entry_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p          public.entries;
  v_refunded bigint;
begin
  perform public.assert_allowed();
  p := engine.own_entry(auth.uid(), p_parent_entry_id);
  if p.type <> 'expense' or p.status <> 'done' then
    perform engine.raise_error('refund_parent_not_expense', jsonb_build_object(
      'parent_entry_id', p.id, 'type', p.type, 'status', p.status));
  end if;
  select coalesce(sum(amount_kzt_minor), 0)::bigint into v_refunded
  from public.entries
  where parent_entry_id = p.id and status = 'done' and id is distinct from p_entry_id;
  return jsonb_build_object('parent_amount_minor', p.amount_kzt_minor, 'refunded_minor', v_refunded,
                            'remaining_minor', p.amount_kzt_minor - v_refunded);
end $$;

revoke all on function public.update_entry(uuid, jsonb), public.delete_entry(uuid),
  public.refund_remaining(uuid, uuid) from public, anon;
grant execute on function public.update_entry(uuid, jsonb), public.delete_entry(uuid),
  public.refund_remaining(uuid, uuid) to authenticated;

-- 5. Лента: у возврата ссылка на трату (дата, сумма, заголовок), у траты сколько по ней возвращено
-- (новые колонки в конце, как требует create or replace view).
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
       e.adjustment_target, e.adjustment_sign, e.adjustment_mode, e.adjustment_affects_advance,
       e.parent_entry_id, p.occurred_on as parent_occurred_on, p.amount_minor as parent_amount_minor,
       p.title as parent_title,
       coalesce(r.refunded, 0)::bigint as refunded_minor
from public.entries e
left join public.accounts a on a.id = e.account_id
left join public.accounts t on t.id = e.to_account_id
left join public.categories c on c.id = e.category_id
left join public.entries p on p.id = e.parent_entry_id
left join (
  select parent_entry_id, sum(amount_minor) as refunded
  from public.entries
  where user_id = (select auth.uid()) and type = 'refund' and status = 'done'
  group by parent_entry_id
) r on r.parent_entry_id = e.id
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

-- 6. Разбор долга: у возврата покупки заголовок его траты, чтобы строка называла покупку
-- (новая колонка в конце; скопировано с 20261110120000_settlement_and_netting.sql).
create or replace view public.v_settlement_breakdown with (security_invoker = true) as
select d.entry_id, d.side, e.type, e.occurred_on, e.occurred_at, e.created_at, e.seq,
       e.title, c.name as category_name, e.account_id, a.name as account_name, t.name as to_account_name,
       e.purpose, e.source, e.transfer_purpose, e.settlement_direction, e.amount_minor, e.currency,
       d.delta_minor,
       (sum(d.delta_minor) over (partition by d.side
          order by e.occurred_on, e.occurred_at nulls last, e.created_at, e.seq))::bigint as side_after_minor,
       p.title as parent_title
from (
  select l.entry_id, l.target as side, sum(l.delta_minor)::bigint as delta_minor
  from public.ledger_entries l
  where l.user_id = (select auth.uid()) and l.target in ('company_owes_me', 'i_owe_company')
  group by l.entry_id, l.target
) d
join public.entries e on e.id = d.entry_id
left join public.accounts a on a.id = e.account_id
left join public.accounts t on t.id = e.to_account_id
left join public.categories c on c.id = e.category_id
left join public.entries p on p.id = e.parent_entry_id;

revoke all on public.v_settlement_breakdown from anon, authenticated;
grant select on public.v_settlement_breakdown to authenticated;

revoke all on all functions in schema engine from public;
