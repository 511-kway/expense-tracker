-- Корректировки (док 03, 4.7; ADR-0006, ADR-0008; док 06, раздел 7; spec.md: цель остаток с авансом или без,
-- режим «скрыта» или «в разрезах трат»; долговая корректировка без счёта, сторона не уходит в минус).
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(38);

-- Каждый сценарий у своего пользователя: чистый учёт (по умолчанию с 01.11.2026), категория «Реклама».
create function pg_temp.scenario(p_n int, p_i_owe bigint default 0, p_start date default '2026-11-01',
                                  p_owe_me bigint default 0) returns void language plpgsql as $$
declare v_uid uuid := ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (v_uid, 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', v_uid, true);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform public.setup_start(p_start, p_owe_me, p_i_owe);
  perform public.create_category('Реклама');
end $$;

create function pg_temp.login_as_stranger() returns void language plpgsql as $$
begin
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000cc', 'stranger@example.com');
  insert into public.app_users (email, user_id, allowed) values ('stranger@example.com', '00000000-0000-0000-0000-0000000000cc', false);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000cc', 'role', 'authenticated')::text, true);
end $$;

create function pg_temp.account(p_name text, p_total bigint default 0, p_company bigint default 0,
                                p_start date default '2026-11-01') returns uuid language sql as $$
  select (public.create_account(p_name => p_name, p_type => 'card', p_start_date => p_start,
            p_total_minor => p_total, p_company_minor => p_company) ->> 'account_id')::uuid
$$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

create function pg_temp.expense(p_account text, p_purpose text, p_amount bigint, p_source text default null,
                                p_date date default '2026-11-02') returns jsonb language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'expense', 'occurred_on', p_date, 'amount_minor', p_amount, 'currency', 'KZT',
    'account_id', pg_temp.acc(p_account), 'purpose', p_purpose, 'source', p_source,
    'category_id', (select id from public.categories where name = 'Реклама'))))
$$;

create function pg_temp.income(p_account text, p_amount bigint, p_date date default '2026-11-02')
returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object(
    'type', 'income', 'occurred_on', p_date, 'amount_minor', p_amount, 'account_id', pg_temp.acc(p_account)))
$$;

-- Остаток и аванс счёта, обе стороны долга.
create function pg_temp.state(p_account text)
returns table (bal bigint, adv bigint, owe_me bigint, i_owe bigint) language sql as $$
  select b.balance_minor, b.advance_minor, s.company_owes_me_minor, s.i_owe_company_minor
  from public.v_account_balances b, public.v_company_settlement s where b.name = p_account
$$;

-- Инварианты (док 03, раздел 10; док 06, раздел 13): аванс ≥ 0, стороны ≥ 0, итог = разница,
-- остаток в выборке = сумма дельт остатка по журналу.
create function pg_temp.invariants_hold() returns boolean language sql as $$
  select (select bool_and(advance_minor >= 0) from public.v_account_balances) is not false
     and (select company_owes_me_minor >= 0 and i_owe_company_minor >= 0
                 and net_minor = company_owes_me_minor - i_owe_company_minor
          from public.v_company_settlement)
     and not exists (
       select 1 from public.v_account_balances b
       where b.balance_minor <> (select coalesce(sum(delta_minor), 0) from public.ledger_entries l
                                 where l.account_id = b.account_id and l.target = 'balance'))
$$;

create function pg_temp.error_of(sql text) returns jsonb language plpgsql as $$
declare v_msg text; v_detail text;
begin
  execute sql;
  return null;
exception when others then
  get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  return jsonb_build_object('code', v_msg, 'detail', nullif(v_detail, '')::jsonb);
end $$;

-- Коды предупреждений ответа.
create function pg_temp.warning_codes(p_result jsonb) returns text[] language sql as $$
  select coalesce(array_agg(w ->> 'code' order by ord), '{}')
  from jsonb_array_elements(p_result -> 'warnings') with ordinality as t (w, ord)
$$;

create function pg_temp.topup(p_account text, p_amount bigint, p_date date default '2026-11-02')
returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object(
    'type', 'company_topup', 'occurred_on', p_date, 'amount_minor', p_amount, 'account_id', pg_temp.acc(p_account)))
$$;

-- Корректировка остатка: знак, режим, «меняет аванс».
create function pg_temp.adjust(p_account text, p_sign int, p_amount bigint, p_mode text default 'plug_hidden',
                               p_affects_advance boolean default false, p_date date default '2026-11-03')
returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object(
    'type', 'adjustment', 'occurred_on', p_date, 'amount_minor', p_amount, 'account_id', pg_temp.acc(p_account),
    'adjustment_target', 'balance', 'adjustment_sign', p_sign, 'adjustment_mode', p_mode,
    'adjustment_affects_advance', p_affects_advance))
$$;

-- Долговая корректировка: сторона долга, знак.
create function pg_temp.adjust_debt(p_side text, p_sign int, p_amount bigint, p_date date default '2026-11-03')
returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object(
    'type', 'adjustment', 'occurred_on', p_date, 'amount_minor', p_amount,
    'adjustment_target', p_side, 'adjustment_sign', p_sign))
$$;

-- TC-ADJUST-HIDDEN: income H1 100000; adjustment H1 sign=-1 amount=18300 mode=plug_hidden.
select pg_temp.scenario(1);
select pg_temp.account('H1');
select pg_temp.income('H1', 10000000);
select set_config('test.hidden', pg_temp.adjust('H1', -1, 1830000) ->> 'entry_id', true);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (8170000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'TC-ADJUST-HIDDEN: balance 81 700 ₸, advance and debt unchanged');

select is((select in_analytics from public.v_entries where entry_id = current_setting('test.hidden')::uuid),
  false, 'TC-ADJUST-HIDDEN: hidden adjustment stays out of spending breakdowns (in_analytics = false)');
select results_eq(
  $$ select adjustment_mode::text, adjustment_sign, adjustment_target::text, adjustment_affects_advance
     from public.entries where id = current_setting('test.hidden')::uuid $$,
  $$ values ('plug_hidden'::text, -1::smallint, 'balance'::text, false) $$,
  'balance adjustment keeps mode, sign, target «остаток» and «меняет аванс» off');

-- «В разрезах трат»: та же корректировка попадает в разрезы (in_analytics = true).
select set_config('test.analytics', pg_temp.adjust('H1', -1, 300000, 'plug_analytics') ->> 'entry_id', true);
select is((select in_analytics from public.v_entries where entry_id = current_setting('test.analytics')::uuid),
  true, 'adjustment «в разрезах трат» goes into spending breakdowns (in_analytics = true)');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (7870000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'adjustment «в разрезах трат» −3 000 ₸: balance 78 700 ₸');

-- Плюс без аванса: только остаток, присланный in_analytics не перебивает режим.
select set_config('test.plus', public.create_entry(jsonb_build_object(
  'type', 'adjustment', 'occurred_on', '2026-11-03', 'amount_minor', 130000, 'account_id', pg_temp.acc('H1'),
  'adjustment_sign', 1, 'adjustment_mode', 'plug_hidden', 'in_analytics', true)) ->> 'entry_id', true);
select results_eq(
  $$ select balance_delta_minor, advance_delta_minor, in_analytics, adjustment_target::text, adjustment_sign,
            adjustment_mode::text, adjustment_affects_advance
     from public.v_entries where entry_id = current_setting('test.plus')::uuid $$,
  $$ values (130000::bigint, 0::bigint, false, 'balance'::text, 1::smallint, 'plug_hidden'::text, false) $$,
  'plus adjustment in the feed: target defaults to «остаток», mode decides in_analytics');
select ok(pg_temp.invariants_hold(), 'invariants hold after balance adjustments');

-- TC-ADJUST-ADVANCE: topup H1 100000; adjustment H1 sign=-1 amount=5000 affects_advance=true.
select pg_temp.scenario(2);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select pg_temp.adjust('H1', -1, 500000, 'plug_hidden', true);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9500000::bigint, 9500000::bigint, 0::bigint, 0::bigint) $$,
  'TC-ADJUST-ADVANCE: advance 95 000 ₸, balance 95 000 ₸, debt unchanged');

-- Плюс с авансом: остаток и аванс плюс.
select pg_temp.adjust('H1', 1, 200000, 'plug_hidden', true);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9700000::bigint, 9700000::bigint, 0::bigint, 0::bigint) $$,
  'plus adjustment with advance: advance and balance +2 000 ₸');

-- Минус с авансом больше аванса: аванс режется на нуле, остаток минус вся сумма (тикет 06).
select pg_temp.income('H1', 3000000);
select pg_temp.adjust('H1', -1, 10000000, 'plug_hidden', true, '2026-11-04');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (2700000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'minus adjustment with advance over the advance: advance stops at zero, balance down by the full sum');

-- Минус уводит остаток в минус: предупреждение, не блокировка.
select is(pg_temp.warning_codes(pg_temp.adjust('H1', -1, 3000000, 'plug_hidden', false, '2026-11-05')),
  '{negative_balance}'::text[], 'adjustment into a negative balance: negative_balance warning, not a block');
select results_eq($$ select bal, adv from pg_temp.state('H1') $$,
  $$ values (-300000::bigint, 0::bigint) $$, 'negative balance adjustment is saved');
select ok(pg_temp.invariants_hold(), 'invariants hold after adjustments with advance');

-- Обязательные поля и проверки корректировки остатка.
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'account_id', pg_temp.acc('H1'),
    'adjustment_mode', 'plug_hidden')) $$),
  '{"code": "missing_required", "detail": {"field": "adjustment_sign"}}'::jsonb, 'adjustment needs a sign');
select is(pg_temp.error_of($$ select pg_temp.adjust('H1', 2, 100) $$),
  '{"code": "field_invalid", "detail": {"field": "adjustment_sign"}}'::jsonb, 'adjustment sign is +1 or −1');
select is(pg_temp.error_of($$ select pg_temp.adjust('H1', -1, -100) $$) ->> 'code', 'amount_not_positive',
  'adjustment amount is the absolute value: the sign lives in adjustment_sign');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'account_id', pg_temp.acc('H1'), 'adjustment_sign', 1)) $$),
  '{"code": "missing_required", "detail": {"field": "adjustment_mode"}}'::jsonb,
  'balance adjustment needs a mode: hidden or in spending breakdowns');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'adjustment_target', 'balance', 'adjustment_sign', 1,
    'adjustment_mode', 'plug_hidden')) $$),
  '{"code": "missing_required", "detail": {"field": "account_id"}}'::jsonb, 'balance adjustment needs an account');
select pg_temp.account('Late', 0, 0, '2026-11-10');
select is(pg_temp.error_of($$ select pg_temp.adjust('Late', 1, 100) $$) ->> 'code', 'entry_before_start',
  'balance adjustment cannot be dated before the account start');

-- Долговая корректировка: без счёта, вне разрезов трат, аванс не трогает.
select pg_temp.scenario(3, 500000, '2026-11-01', 1200000);
select pg_temp.account('H1', 1000000, 1000000);
select set_config('test.debt', public.create_entry(jsonb_build_object(
  'type', 'adjustment', 'occurred_on', '2026-11-03', 'amount_minor', 300000, 'account_id', pg_temp.acc('H1'),
  'adjustment_target', 'company_owes_me', 'adjustment_sign', 1, 'adjustment_mode', 'plug_analytics',
  'adjustment_affects_advance', true)) ->> 'entry_id', true);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (1000000::bigint, 1000000::bigint, 1500000::bigint, 500000::bigint) $$,
  'debt adjustment +3 000 ₸ to «компания должна мне»: balance and advance untouched');
select results_eq(
  $$ select account_id, in_analytics, adjustment_mode::text, adjustment_affects_advance
     from public.entries where id = current_setting('test.debt')::uuid $$,
  $$ values (null::uuid, false, 'plug_hidden'::text, false) $$,
  'debt adjustment has no account, stays out of spending breakdowns and does not touch the advance');
select pg_temp.adjust_debt('i_owe_company', -1, 500000);
select results_eq($$ select owe_me, i_owe from pg_temp.state('H1') $$,
  $$ values (1500000::bigint, 0::bigint) $$, 'debt adjustment −5 000 ₸ brings «я должен компании» to exactly zero');

-- Сторона долга не уходит в минус (проверка в пересчёте).
select is((pg_temp.error_of($$ select pg_temp.adjust_debt('company_owes_me', -1, 1500001) $$) -> 'detail') - 'entry_id'::text,
  '{"side": "company_owes_me", "occurred_on": "2026-11-03", "available_minor": 1500000, "amount_minor": 1500001}'::jsonb,
  'debt adjustment below zero is rejected: debt_below_zero with the side and what was available');
select is(pg_temp.error_of($$ select pg_temp.adjust_debt('company_owes_me', -1, 1500001) $$) ->> 'code',
  'debt_below_zero', 'debt adjustment below zero: code debt_below_zero');
select results_eq($$ select owe_me, i_owe from pg_temp.state('H1') $$,
  $$ values (1500000::bigint, 0::bigint) $$, 'rejected debt adjustment changed nothing');

-- Задним числом: удаление плюса, на котором держится более поздний минус, отклонено с id минуса.
select set_config('test.minus', pg_temp.adjust_debt('company_owes_me', -1, 1400000, '2026-11-06') ->> 'entry_id', true);
select is(pg_temp.error_of(format('select public.delete_entry(%L)', current_setting('test.debt'))),
  jsonb_build_object('code', 'debt_below_zero', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.minus'), 'side', 'company_owes_me', 'occurred_on', '2026-11-06',
    'available_minor', 1200000, 'amount_minor', 1400000)),
  'deleting the plus that a later minus relies on: debt_below_zero names the later adjustment');
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-07', 'amount_minor', 300000, 'adjustment_target', 'company_owes_me',
    'adjustment_sign', 1)) $$, current_setting('test.debt'))) -> 'detail' ->> 'entry_id',
  current_setting('test.minus'), 'moving the plus after the minus: rejected with the minus id');
select results_eq($$ select owe_me, i_owe from pg_temp.state('H1') $$,
  $$ values (100000::bigint, 0::bigint) $$, 'rejected backdated change left the sides as they were');

-- Правка: смена цели и знака пересобирает запись.
select public.update_entry(current_setting('test.minus')::uuid, jsonb_build_object('type', 'adjustment',
  'occurred_on', '2026-11-06', 'amount_minor', 400000, 'account_id', pg_temp.acc('H1'),
  'adjustment_target', 'balance', 'adjustment_sign', -1, 'adjustment_mode', 'plug_hidden',
  'adjustment_affects_advance', true));
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (600000::bigint, 600000::bigint, 1500000::bigint, 0::bigint) $$,
  'editing a debt adjustment into a balance adjustment with advance: full rebuild');
select is(pg_temp.error_of($$ select pg_temp.adjust_debt('company_owes_me', 1, 100, '2026-10-31') $$) ->> 'code',
  'entry_before_start', 'debt adjustment cannot be dated before the accounting start');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'currency', 'USD', 'adjustment_target', 'i_owe_company',
    'adjustment_sign', 1)) $$) ->> 'code', 'foreign_amount_not_supported', 'debt adjustment is in tenge only');

-- Разбор долга показывает долговые корректировки.
select results_eq(
  $$ select title, delta_minor, side_after_minor from public.v_settlement_breakdown
     where side = 'company_owes_me' order by occurred_on, seq $$,
  $$ values ('Стартовый долг'::text, 1200000::bigint, 1200000::bigint), (null, 300000, 1500000) $$,
  'debt breakdown lists the opening debt and the reconciliation adjustment');

-- Стартовые записи — обычные корректировки: правятся и удаляются с полным пересчётом.
select public.update_entry(e.id, jsonb_build_object('type', 'adjustment', 'occurred_on', e.occurred_on,
  'amount_minor', 1100000, 'adjustment_target', 'company_owes_me', 'adjustment_sign', 1, 'title', e.title))
from public.entries e where e.title = 'Стартовый долг' and e.adjustment_target = 'company_owes_me';
select results_eq($$ select owe_me, i_owe from pg_temp.state('H1') $$,
  $$ values (1400000::bigint, 0::bigint) $$, 'opening debt can be edited like any adjustment');
select public.update_entry(e.id, jsonb_build_object('type', 'adjustment', 'occurred_on', e.occurred_on,
  'amount_minor', 1500000, 'account_id', e.account_id, 'adjustment_sign', 1, 'adjustment_mode', 'plug_hidden',
  'adjustment_affects_advance', true, 'title', e.title))
from public.entries e where e.title = 'Стартовый остаток';
select results_eq($$ select bal, adv from pg_temp.state('H1') $$,
  $$ values (1100000::bigint, 1100000::bigint) $$, 'opening balance can be edited like any adjustment');
select is((select count(*) from public.entries where title in ('Стартовый долг', 'Стартовый остаток')
             and adjustment_target is not null and in_analytics = false), 3::bigint,
  'edited opening entries keep their title and stay hidden');
select ok(pg_temp.invariants_hold(), 'invariants hold after debt adjustments');

-- Чужой счёт не корректируется.
select set_config('test.h1', pg_temp.acc('H1')::text, true);
select pg_temp.scenario(4);
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'account_id', %L, 'adjustment_sign', 1,
    'adjustment_mode', 'plug_hidden')) $$, current_setting('test.h1'))) ->> 'code', 'account_not_found',
  'adjustment on another user''s account: account_not_found');
reset role;

select pg_temp.login_as_stranger();
select throws_ok($$ select pg_temp.adjust_debt('i_owe_company', 1, 100) $$, '42501', 'not_allowed',
  'not allowed: adjustment cannot be created');
reset role;

select * from finish();
rollback;
