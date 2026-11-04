-- Возврат покупки (док 03, 4.8 и 8; ADR-0006; док 06, раздел 8 и TC-REFUND-ROUNDING; spec.md).
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(40);

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

create function pg_temp.topup(p_account text, p_amount bigint, p_fee bigint default 0, p_payer text default null,
                              p_date date default '2026-11-02') returns jsonb language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'company_topup', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account), 'fee_minor', p_fee, 'fee_payer', p_payer)))
$$;

create function pg_temp.settle(p_direction text, p_account text, p_amount bigint, p_date date default '2026-11-03')
returns jsonb language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'settlement', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account), 'settlement_direction', p_direction)))
$$;

-- Возврат покупки по трате с id p_parent (счёт берётся у траты).
create function pg_temp.refund(p_parent text, p_amount bigint, p_date date default '2026-11-05')
returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object(
    'type', 'refund', 'occurred_on', p_date, 'amount_minor', p_amount, 'parent_entry_id', p_parent))
$$;

-- TC-REFUND-FULL: topup H1 100000; expense personal H1 30000 source=company (adv=70000, i_owe=30000,
-- bal=70000); refund 30000.
select pg_temp.scenario(1);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select set_config('test.exp', pg_temp.expense('H1', 'personal', 3000000, 'company') ->> 'entry_id', true);
select pg_temp.refund(current_setting('test.exp'), 3000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 10000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-REFUND-FULL: a full возврат покупки of a personal expense with company money rolls it back to zero');
select ok(pg_temp.invariants_hold(), 'TC-REFUND-FULL: invariants hold');
select results_eq(
  $$ select type::text, account_name, category_name, purpose::text, balance_delta_minor, advance_delta_minor,
            i_owe_company_delta_minor, parent_entry_id::text, parent_occurred_on, parent_amount_minor
     from public.v_entries where type = 'refund' $$,
  $$ values ('refund', 'H1'::text, 'Реклама'::text, 'personal'::text, 3000000::bigint, 3000000::bigint,
             -3000000::bigint, current_setting('test.exp'), '2026-11-02'::date, 3000000::bigint) $$,
  'the feed shows the возврат покупки on the account of its expense, linked to the expense');
select is((select refunded_minor from public.v_entries where entry_id = current_setting('test.exp')::uuid),
  3000000::bigint, 'the feed shows how much of the expense is refunded');

-- TC-REFUND-PARTIAL: как выше, возврат 15000.
select pg_temp.scenario(2);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select set_config('test.exp', pg_temp.expense('H1', 'personal', 3000000, 'company') ->> 'entry_id', true);
select pg_temp.refund(current_setting('test.exp'), 1500000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (8500000::bigint, 8500000::bigint, 0::bigint, 1500000::bigint) $$,
  'TC-REFUND-PARTIAL: half of the возврат покупки restores half of the advance and the debt');
select is(public.refund_remaining(current_setting('test.exp')::uuid),
  '{"parent_amount_minor": 3000000, "refunded_minor": 1500000, "remaining_minor": 1500000, "currency": "KZT"}'::jsonb,
  'the server tells the form how much is still refundable');
select is(pg_temp.error_of(format('select pg_temp.refund(%L, 1500001)', current_setting('test.exp'))) #- '{detail,entry_id}',
  jsonb_build_object('code', 'refund_too_big', 'detail', jsonb_build_object('occurred_on', '2026-11-05',
    'parent_entry_id', current_setting('test.exp'), 'available_minor', 1500000, 'amount_minor', 1500001)),
  'a возврат покупки above the not yet refunded remainder is rejected');

-- TC-REFUND-CAP: как выше, возврат 40000 при исходной 30000.
select pg_temp.scenario(3);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select set_config('test.exp', pg_temp.expense('H1', 'personal', 3000000, 'company') ->> 'entry_id', true);
select is(pg_temp.error_of(format('select pg_temp.refund(%L, 4000000)', current_setting('test.exp'))) ->> 'code',
  'refund_too_big', 'TC-REFUND-CAP: 40 000 back for an expense of 30 000 is rejected');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (7000000::bigint, 7000000::bigint, 0::bigint, 3000000::bigint) $$,
  'TC-REFUND-CAP: the state did not change');
select is((select count(*) from public.entries where type = 'refund'), 0::bigint,
  'TC-REFUND-CAP: the rejected возврат покупки is not created');

-- TC-REFUND-ROUNDING: topup H1 100.01; expense personal H1 300.00 source=company (company_part=10001,
-- adv=0, i_owe=100.01); refund 100.00 три раза.
select pg_temp.scenario(4);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10001);
select set_config('test.exp', pg_temp.expense('H1', 'personal', 30000, 'company') ->> 'entry_id', true);
select pg_temp.refund(current_setting('test.exp'), 10000);
select is((select adv from pg_temp.state('H1')), 3333::bigint,
  'TC-REFUND-ROUNDING: the first third restores floor(10001 · 1/3) = 3333 of the advance');
select pg_temp.refund(current_setting('test.exp'), 10000, '2026-11-06');
select pg_temp.refund(current_setting('test.exp'), 10000, '2026-11-07');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10001::bigint, 10001::bigint, 0::bigint, 0::bigint) $$,
  'TC-REFUND-ROUNDING: three partial возвраты close the expense exactly, no tiyn is lost');
select ok(pg_temp.invariants_hold(), 'TC-REFUND-ROUNDING: invariants hold');

-- Рабочая трата со сплитом: аванс 10 000, трата 30 000 (из аванса 10 000, компания должна мне 20 000).
-- Частичный возврат 10 000, затем остаток 20 000: всё закрывается в ноль.
select pg_temp.scenario(5);
select pg_temp.account('H1');
select pg_temp.topup('H1', 1000000);
select set_config('test.exp', pg_temp.expense('H1', 'work', 3000000) ->> 'entry_id', true);
select pg_temp.refund(current_setting('test.exp'), 1000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (-1000000::bigint, 333333::bigint, 1333334::bigint, 0::bigint) $$,
  'partial возврат покупки of a work expense: floor(10 000 · 1/3) of the advance, floor(20 000 · 1/3) of «компания должна мне»');
select pg_temp.refund(current_setting('test.exp'), 2000000, '2026-11-06');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (1000000::bigint, 1000000::bigint, 0::bigint, 0::bigint) $$,
  'full возврат покупки of a work expense restores the advance and closes «компания должна мне» to zero');
select ok(pg_temp.invariants_hold(), 'work expense refund: invariants hold');

-- Личная трата своими: только остаток.
select pg_temp.scenario(6);
select pg_temp.account('H1', 5000000);
select set_config('test.exp', pg_temp.expense('H1', 'personal', 2000000) ->> 'entry_id', true);
select pg_temp.refund(current_setting('test.exp'), 2000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (5000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'возврат покупки of a personal expense with own money only returns the money to the account');

-- Долг по трате уже погашен: восстановленное уходит в другую сторону долга.
select pg_temp.scenario(7);
select pg_temp.account('H1', 5000000);
select set_config('test.exp', pg_temp.expense('H1', 'work', 2000000) ->> 'entry_id', true);
select pg_temp.settle('company_paid_me', 'H1', 2000000);
select pg_temp.refund(current_setting('test.exp'), 2000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (7000000::bigint, 0::bigint, 0::bigint, 2000000::bigint) $$,
  'the company already paid for the work expense: after the возврат покупки I owe the company');
select ok(pg_temp.invariants_hold(), 'refund after the company paid: invariants hold');
select pg_temp.scenario(12);
select pg_temp.account('H1', 5000000);
select pg_temp.account('H2');
select pg_temp.topup('H2', 1000000);
select set_config('test.exp2', pg_temp.expense('H2', 'personal', 1000000, 'company') ->> 'entry_id', true);
select pg_temp.settle('i_paid_company', 'H1', 1000000, '2026-11-04');
select pg_temp.refund(current_setting('test.exp2'), 1000000, '2026-11-06');
select results_eq($$ select adv, owe_me, i_owe from pg_temp.state('H2') $$,
  $$ values (1000000::bigint, 1000000::bigint, 0::bigint) $$,
  'I already paid the company for the personal expense: after the возврат покупки the company owes me');
select ok(pg_temp.invariants_hold(), 'refund after repayment: invariants hold');

-- Проверка в пересчёте: правка и удаление траты задним числом (ADR-0006).
select pg_temp.scenario(8);
select pg_temp.account('H1');
select pg_temp.account('H2', p_start => '2026-11-01');
select pg_temp.topup('H1', 10000000);
select set_config('test.exp', pg_temp.expense('H1', 'personal', 3000000, 'company') ->> 'entry_id', true);
select set_config('test.ref', pg_temp.refund(current_setting('test.exp'), 2000000) ->> 'entry_id', true);
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'expense',
    'occurred_on', '2026-11-02', 'amount_minor', 1000000, 'account_id', pg_temp.acc('H1'), 'purpose', 'personal',
    'source', 'company', 'category_id', (select id from public.categories where name = 'Реклама'))) $$,
    current_setting('test.exp'))),
  jsonb_build_object('code', 'refund_too_big', 'detail', jsonb_build_object('entry_id', current_setting('test.ref'),
    'occurred_on', '2026-11-05', 'parent_entry_id', current_setting('test.exp'), 'available_minor', 1000000,
    'amount_minor', 2000000)),
  'lowering the expense below what is already refunded is rejected with the id of the возврат покупки');
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'expense',
    'occurred_on', '2026-11-06', 'amount_minor', 3000000, 'account_id', pg_temp.acc('H1'), 'purpose', 'personal',
    'source', 'company', 'category_id', (select id from public.categories where name = 'Реклама'))) $$,
    current_setting('test.exp'))) ->> 'code',
  'refund_before_expense', 'moving the expense after its возврат покупки is rejected');
select is(pg_temp.error_of(format('select public.delete_entry(%L)', current_setting('test.exp'))),
  jsonb_build_object('code', 'expense_has_refunds', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.exp'), 'refund_count', 1)),
  'an expense with a возврат покупки cannot be deleted');
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'income',
    'occurred_on', '2026-11-02', 'amount_minor', 3000000, 'account_id', pg_temp.acc('H1'))) $$,
    current_setting('test.exp'))) ->> 'code',
  'expense_has_refunds', 'an expense with a возврат покупки cannot change its type');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9000000::bigint, 9000000::bigint, 0::bigint, 1000000::bigint) $$,
  'rejected edits and deletes left the state as it was');
-- Правка возврата сверх остатка тоже отклоняется; правка в пределах проходит.
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'refund',
    'occurred_on', '2026-11-05', 'amount_minor', 3000001, 'parent_entry_id', %L)) $$,
    current_setting('test.ref'), current_setting('test.exp'))) ->> 'code',
  'refund_too_big', 'editing the возврат покупки above the expense is rejected');
select is(public.refund_remaining(current_setting('test.exp')::uuid, current_setting('test.ref')::uuid) ->> 'remaining_minor',
  '3000000', 'while editing a возврат покупки the remainder does not count it');
-- Трата переехала на другой счёт: возврат следует за ней.
select public.create_entry(jsonb_build_object('type', 'income', 'occurred_on', '2026-11-02',
  'amount_minor', 5000000, 'account_id', pg_temp.acc('H2')));
select public.update_entry(current_setting('test.exp')::uuid, jsonb_build_object('type', 'expense',
  'occurred_on', '2026-11-02', 'amount_minor', 3000000, 'account_id', pg_temp.acc('H2'), 'purpose', 'personal',
  'category_id', (select id from public.categories where name = 'Реклама')));
select results_eq($$ select account_name, balance_delta_minor from public.v_entries where type = 'refund' $$,
  $$ values ('H2'::text, 2000000::bigint) $$,
  'the возврат покупки follows its expense to another account');
select results_eq($$ select * from pg_temp.state('H2') $$,
  $$ values (4000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'the expense is now own money on H2: the возврат покупки only returns money there');
-- Сначала удаляется возврат, потом трата.
select public.delete_entry(current_setting('test.ref')::uuid);
select public.delete_entry(current_setting('test.exp')::uuid);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 10000000::bigint, 0::bigint, 0::bigint) $$,
  'after its возврат покупки is deleted the expense can be deleted');
select ok(pg_temp.invariants_hold(), 'edits and deletes: invariants hold');

-- Ввод: трата обязательна, только своя учтённая трата, не раньше траты; счёт берётся у траты.
select pg_temp.scenario(9);
select pg_temp.account('H1', 5000000);
select pg_temp.account('H2');
select set_config('test.exp', pg_temp.expense('H1', 'personal', 1000000) ->> 'entry_id', true);
select set_config('test.inc', pg_temp.income('H1', 100) ->> 'entry_id', true);
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'refund',
    'occurred_on', '2026-11-05', 'amount_minor', 100)) $$),
  '{"code": "missing_required", "detail": {"field": "parent_entry_id"}}'::jsonb,
  'возврат покупки needs its expense');
select is(pg_temp.error_of(format('select pg_temp.refund(%L, 100)', current_setting('test.inc'))) ->> 'code',
  'refund_parent_not_expense', 'возврат покупки only refers to an expense');
select is(pg_temp.error_of(format('select pg_temp.refund(%L, 100, ''2026-11-01'')', current_setting('test.exp'))),
  jsonb_build_object('code', 'refund_before_expense', 'detail', jsonb_build_object('occurred_on', '2026-11-01',
    'parent_entry_id', current_setting('test.exp'), 'parent_occurred_on', '2026-11-02')),
  'возврат покупки cannot be earlier than its expense');
select public.create_entry(jsonb_build_object('type', 'refund', 'occurred_on', '2026-11-05',
  'amount_minor', 100, 'parent_entry_id', current_setting('test.exp'), 'account_id', pg_temp.acc('H2')));
select results_eq($$ select account_name from public.v_entries where type = 'refund' $$,
  $$ values ('H1'::text) $$, 'возврат покупки arrives on the account of its expense, a sent account is ignored');

-- Разбор долга показывает возврат покупки.
select pg_temp.scenario(10);
select pg_temp.account('H1');
select pg_temp.topup('H1', 1000000);
select set_config('test.exp', pg_temp.expense('H1', 'personal', 1000000, 'company') ->> 'entry_id', true);
select pg_temp.refund(current_setting('test.exp'), 400000);
select public.update_entry(current_setting('test.exp')::uuid, jsonb_build_object('type', 'expense',
  'occurred_on', '2026-11-02', 'amount_minor', 1000000, 'account_id', pg_temp.acc('H1'), 'purpose', 'personal',
  'source', 'company', 'title', 'Наушники', 'category_id', (select id from public.categories where name = 'Реклама')));
select results_eq($$ select type::text, delta_minor, side_after_minor, parent_title from public.v_settlement_breakdown
                     where side = 'i_owe_company' order by occurred_on, seq $$,
  $$ values ('expense'::text, 1000000::bigint, 1000000::bigint, null::text), ('refund', -400000, 600000, 'Наушники') $$,
  'breakdown of «я должен компании» shows the возврат покупки');
select set_config('test.exp10', current_setting('test.exp'), true);

-- Чужая трата не принимается.
select pg_temp.scenario(11);
select is(pg_temp.error_of(format('select pg_temp.refund(%L, 100)', current_setting('test.exp10'))) ->> 'code',
  'entry_not_found', 'other user cannot refund someone else''s expense');
select is(pg_temp.error_of(format('select public.refund_remaining(%L)', current_setting('test.exp10'))) ->> 'code',
  'entry_not_found', 'other user cannot see the remainder of someone else''s expense');

reset role;
select pg_temp.login_as_stranger();
select throws_ok($$ select public.refund_remaining('00000000-0000-0000-0000-000000000001') $$, '42501', 'not_allowed',
  'not allowed: refund_remaining raises not_allowed');
reset role;

select * from finish();
rollback;
