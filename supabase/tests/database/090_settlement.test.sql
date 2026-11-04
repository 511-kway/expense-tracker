-- Погашение долга и взаимозачёт (док 03, 4.6 и 8; ADR-0006; док 06, разделы 5 и 9; spec.md:
-- счёт в погашении обязателен, деньги от компании приходят как свои; новый тип «взаимозачёт»).
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(42);

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

create function pg_temp.topup(p_account text, p_amount bigint, p_fee bigint default 0, p_payer text default null,
                              p_date date default '2026-11-02') returns jsonb language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'company_topup', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account), 'fee_minor', p_fee, 'fee_payer', p_payer)))
$$;

create function pg_temp.withdraw(p_account text, p_amount bigint, p_date date default '2026-11-02')
returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object(
    'type', 'company_advance_return', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account)))
$$;

create function pg_temp.transfer(p_from text, p_to text, p_purpose text, p_amount bigint, p_fee bigint default 0,
                                 p_payer text default null, p_date date default '2026-11-03') returns jsonb
language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'transfer', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_from), 'to_account_id', pg_temp.acc(p_to), 'transfer_purpose', p_purpose,
    'fee_minor', p_fee, 'fee_payer', p_payer)))
$$;

-- Остаток и аванс двух счетов, обе стороны долга.
create function pg_temp.state2(p_a text, p_b text)
returns table (bal_a bigint, adv_a bigint, bal_b bigint, adv_b bigint, owe_me bigint, i_owe bigint) language sql as $$
  select a.balance_minor, a.advance_minor, b.balance_minor, b.advance_minor,
         s.company_owes_me_minor, s.i_owe_company_minor
  from public.v_account_balances a, public.v_account_balances b, public.v_company_settlement s
  where a.name = p_a and b.name = p_b
$$;

create function pg_temp.settle(p_direction text, p_account text, p_amount bigint, p_date date default '2026-11-03')
returns jsonb language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'settlement', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account), 'settlement_direction', p_direction)))
$$;

create function pg_temp.net(p_amount bigint, p_date date default '2026-11-03') returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object('type', 'netting', 'occurred_on', p_date, 'amount_minor', p_amount))
$$;

-- TC-SETTLE-IPAID: topup H1 100000; expense personal H1 30000 source=company (i_owe=30000);
-- settlement i_paid_company 30000 account=KS.
select pg_temp.scenario(1);
select pg_temp.account('H1');
select pg_temp.account('KS');
select pg_temp.topup('H1', 10000000);
select pg_temp.expense('H1', 'personal', 3000000, 'company');
select set_config('test.paid', pg_temp.settle('i_paid_company', 'KS', 3000000)::text, true);
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 7000000::bigint, 7000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-SETTLE-IPAID: погашение долга pays off «я должен компании» from the account, the advance does not move');

select is(current_setting('test.paid')::jsonb -> 'warnings',
  jsonb_build_array(jsonb_build_object('code', 'negative_balance',
    'entry_id', current_setting('test.paid')::jsonb ->> 'entry_id', 'occurred_on', '2026-11-03',
    'account_id', pg_temp.acc('KS'), 'balance_minor', -3000000)),
  'the repayment warns that the account went below zero, it is not blocked');
select ok(pg_temp.invariants_hold(), 'TC-SETTLE-IPAID: invariants hold');

-- TC-SETTLE-CAP: погасить больше стороны долга нельзя, состояние не меняется.
select pg_temp.expense('H1', 'personal', 3000000, 'company', '2026-11-04');
select is(pg_temp.error_of($$ select pg_temp.settle('i_paid_company', 'KS', 5000000, '2026-11-05') $$)
    #- '{detail,entry_id}',
  '{"code": "debt_overpay", "detail": {"occurred_on": "2026-11-05", "side": "i_owe_company",
    "available_minor": 3000000, "amount_minor": 5000000}}'::jsonb,
  'TC-SETTLE-CAP: 50 000 at a debt of 30 000 is rejected with the debt on that date');
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 4000000::bigint, 4000000::bigint, 0::bigint, 3000000::bigint) $$,
  'TC-SETTLE-CAP: the state did not change');
select is((select count(*) from public.entries where type = 'settlement'), 1::bigint,
  'TC-SETTLE-CAP: the rejected repayment is not created');

-- TC-SETTLE-COMPANY-PAID: income H1 50000; expense work H1 20000 (owe_me=20000);
-- settlement company_paid_me 20000 account=H1.
select pg_temp.scenario(2);
select pg_temp.account('H1');
select pg_temp.income('H1', 5000000);
select pg_temp.expense('H1', 'work', 2000000);
select pg_temp.settle('company_paid_me', 'H1', 2000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (5000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'TC-SETTLE-COMPANY-PAID: the company paid its debt, the money arrives as own money, not advance');
select is(pg_temp.error_of($$ select pg_temp.settle('company_paid_me', 'H1', 1) $$)
    -> 'detail' ->> 'side', 'company_owes_me',
  'the company cannot pay more than «компания должна мне»');
-- На счёте с авансом деньги компании по долгу тоже свои: аванс не растёт.
select pg_temp.account('KP', 1000000, 1000000);
select pg_temp.expense('H1', 'work', 500000, p_date => '2026-11-04');
select pg_temp.settle('company_paid_me', 'KP', 500000, '2026-11-05');
select results_eq($$ select * from pg_temp.state('KP') $$,
  $$ values (1500000::bigint, 1000000::bigint, 0::bigint, 0::bigint) $$,
  'money from the company for its debt does not become advance even on an account with advance');
select ok(pg_temp.invariants_hold(), 'TC-SETTLE-COMPANY-PAID: invariants hold');

-- Проверки погашения: счёт обязателен (spec.md), направление обязательно, дата не раньше старта счёта.
select pg_temp.account('Поздний', p_start => '2026-11-10');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'settlement',
    'occurred_on', '2026-11-05', 'amount_minor', 100, 'settlement_direction', 'company_paid_me')) $$),
  '{"code": "missing_required", "detail": {"field": "account_id"}}'::jsonb,
  'погашение долга needs an account');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'settlement',
    'occurred_on', '2026-11-05', 'amount_minor', 100, 'account_id', pg_temp.acc('H1'))) $$),
  '{"code": "missing_required", "detail": {"field": "settlement_direction"}}'::jsonb,
  'погашение долга needs a direction');
select is(pg_temp.error_of($$ select pg_temp.settle('company_paid_me', 'Поздний', 100, '2026-11-05') $$)
    ->> 'code', 'entry_before_start', 'погашение долга before the start date of the account is rejected');

-- Лента: погашение со счётом и направлением; правка меняет направление, смена типа очищает его.
select results_eq(
  $$ select type::text, settlement_direction::text, account_name, balance_delta_minor, advance_delta_minor,
            company_owes_me_delta_minor, i_owe_company_delta_minor
     from public.v_entries where type = 'settlement' and account_name = 'KP' $$,
  $$ values ('settlement', 'company_paid_me', 'KP'::text, 500000::bigint, 0::bigint, -500000::bigint, 0::bigint) $$,
  'entries feed: the repayment with its direction and what it did');
select set_config('test.s', (select entry_id::text from public.v_entries where type = 'settlement' and account_name = 'KP'), true);
select public.update_entry(current_setting('test.s')::uuid, jsonb_build_object('type', 'settlement',
  'occurred_on', '2026-11-05', 'amount_minor', 200000, 'account_id', pg_temp.acc('KP'),
  'settlement_direction', 'company_paid_me'));
select results_eq($$ select * from pg_temp.state('KP') $$,
  $$ values (1200000::bigint, 1000000::bigint, 300000::bigint, 0::bigint) $$,
  'edit of a repayment: the amount is replaced');
select public.update_entry(current_setting('test.s')::uuid, jsonb_build_object('type', 'income',
  'occurred_on', '2026-11-05', 'amount_minor', 200000, 'account_id', pg_temp.acc('KP'),
  'settlement_direction', 'company_paid_me'));
select is((select settlement_direction::text from public.entries where id = current_setting('test.s')::uuid), null,
  'edit to another type clears the direction');

-- TC-BACKDATE-DELETE-GUARD (ADR-0006): 2026-03-01 topup H1 100000; 2026-03-02 expense personal
-- H1 30000 source=company; 2026-03-05 settlement i_paid_company 30000 account=KS; delete траты.
select pg_temp.scenario(3, p_start => '2026-03-01');
select pg_temp.account('H1', p_start => '2026-03-01');
select pg_temp.account('KS', p_start => '2026-03-01');
select pg_temp.topup('H1', 10000000, p_date => '2026-03-01');
select set_config('test.debt', pg_temp.expense('H1', 'personal', 3000000, 'company', '2026-03-02') ->> 'entry_id', true);
select set_config('test.paid', pg_temp.settle('i_paid_company', 'KS', 3000000, '2026-03-05') ->> 'entry_id', true);
select is(pg_temp.error_of(format('select public.delete_entry(%L)', current_setting('test.debt'))),
  jsonb_build_object('code', 'debt_overpay', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.paid'), 'occurred_on', '2026-03-05',
    'side', 'i_owe_company', 'available_minor', 0, 'amount_minor', 3000000)),
  'TC-BACKDATE-DELETE-GUARD: deleting the debt would make the later repayment exceed it');
select is((select count(*) from public.entries where id = current_setting('test.debt')::uuid), 1::bigint,
  'TC-BACKDATE-DELETE-GUARD: the expense is not deleted');
select results_eq($$ select * from pg_temp.state2('H1', 'KS') $$,
  $$ values (7000000::bigint, 7000000::bigint, -3000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'TC-BACKDATE-DELETE-GUARD: the state is as it was');

-- TC-BACKDATE-INSERT-GUARD: 2026-03-01 topup H1 100000; 2026-03-02 expense personal H1 30000
-- source=company; 2026-03-03 settlement i_paid_company 30000; create settlement 10000 датой 2026-03-02.
select pg_temp.scenario(4, p_start => '2026-03-01');
select pg_temp.account('H1', p_start => '2026-03-01');
select pg_temp.account('KS', p_start => '2026-03-01');
select pg_temp.topup('H1', 10000000, p_date => '2026-03-01');
select pg_temp.expense('H1', 'personal', 3000000, 'company', '2026-03-02');
select set_config('test.paid', pg_temp.settle('i_paid_company', 'KS', 3000000, '2026-03-03') ->> 'entry_id', true);
select is(pg_temp.error_of($$ select pg_temp.settle('i_paid_company', 'KS', 1000000, '2026-03-02') $$),
  jsonb_build_object('code', 'debt_overpay', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.paid'), 'occurred_on', '2026-03-03',
    'side', 'i_owe_company', 'available_minor', 2000000, 'amount_minor', 3000000)),
  'TC-BACKDATE-INSERT-GUARD: the error names the repayment of 03.03, the debt to it would be 20 000');
select is((select count(*) from public.entries where type = 'settlement'), 1::bigint,
  'TC-BACKDATE-INSERT-GUARD: nothing is created');
select ok(pg_temp.invariants_hold(), 'TC-BACKDATE-INSERT-GUARD: invariants hold');

-- Взаимозачёт (spec.md): обе стороны долга минус одна сумма, без счёта, не больше меньшей стороны.
-- Стартовый долг: компания должна мне 20 000, я должен компании 30 000.
select pg_temp.scenario(5, 3000000, p_owe_me => 2000000);
select pg_temp.account('H1', 1000000, 400000);
-- Счёт во взаимозачёте не хранится: денег не было.
select set_config('test.net', public.create_entry(jsonb_build_object('type', 'netting',
  'occurred_on', '2026-11-03', 'amount_minor', 2000000, 'account_id', pg_temp.acc('H1')))::text, true);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (1000000::bigint, 400000::bigint, 0::bigint, 1000000::bigint) $$,
  'взаимозачёт lowers both sides by the same amount, balances and advances do not move');
select is(current_setting('test.net')::jsonb -> 'warnings', '[]'::jsonb, 'взаимозачёт gives no warnings');
select results_eq(
  $$ select type::text, account_id, balance_delta_minor, advance_delta_minor, company_owes_me_delta_minor,
            i_owe_company_delta_minor
     from public.v_entries where type = 'netting' $$,
  $$ values ('netting', null::uuid, 0::bigint, 0::bigint, -2000000::bigint, -2000000::bigint) $$,
  'entries feed: взаимозачёт keeps no account, minus on both sides');
select is(pg_temp.error_of($$ select pg_temp.net(1, '2026-11-04') $$) #- '{detail,entry_id}',
  jsonb_build_object('code', 'netting_too_big', 'detail', jsonb_build_object(
    'occurred_on', '2026-11-04', 'available_minor', 0, 'company_owes_me_minor', 0,
    'i_owe_company_minor', 1000000, 'amount_minor', 1)),
  'взаимозачёт above the smaller side is rejected with both sides on that date');
select ok(pg_temp.invariants_hold(), 'взаимозачёт: invariants hold');
-- Взаимозачёт 01.11 на 5 000 влез бы, но тогда к 03.11 компания должна мне только 15 000.
select is(pg_temp.error_of($$ select pg_temp.net(500000, '2026-11-01') $$),
  jsonb_build_object('code', 'netting_too_big', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.net')::jsonb ->> 'entry_id', 'occurred_on', '2026-11-03',
    'available_minor', 1500000, 'company_owes_me_minor', 1500000, 'i_owe_company_minor', 2500000,
    'amount_minor', 2000000)),
  'a backdated взаимозачёт that leaves the later one above the smaller side is rejected, the later one is named');
select is((select count(*) from public.entries where type = 'netting'), 1::bigint,
  'the rejected взаимозачёт is not created');
select is(pg_temp.error_of($$ select pg_temp.net(100, '2026-10-31') $$) ->> 'code', 'entry_before_start',
  'взаимозачёт before the accounting start date is rejected');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'netting',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'currency', 'USD')) $$) ->> 'code',
  'foreign_amount_not_supported', 'взаимозачёт is in tenge only');

-- Взаимозачёт из долга по тратам; удаление траты задним числом отклоняется (ADR-0006).
select pg_temp.scenario(6);
select pg_temp.account('H1', 5000000, 4000000);
select pg_temp.expense('H1', 'personal', 1000000, 'company');
select set_config('test.work', pg_temp.expense('H1', 'work', 4000000) ->> 'entry_id', true);
select is(pg_temp.error_of($$ select pg_temp.net(1000000, '2026-11-01') $$) -> 'detail' ->> 'available_minor', '0',
  'a backdated взаимозачёт cannot close a debt that appeared later');
select set_config('test.net', pg_temp.net(1000000) ->> 'entry_id', true);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (0::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'взаимозачёт closes the debt that the expenses made: in the end we are settled');
select is(pg_temp.error_of(format('select public.delete_entry(%L)', current_setting('test.work'))),
  jsonb_build_object('code', 'netting_too_big', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.net'), 'occurred_on', '2026-11-03', 'available_minor', 0,
    'company_owes_me_minor', 0, 'i_owe_company_minor', 1000000, 'amount_minor', 1000000)),
  'deleting the work expense would leave the later взаимозачёт without a side, it is rejected');
select ok(pg_temp.invariants_hold(), 'взаимозачёт from expenses: invariants hold');

-- Разбор долга (v_settlement_breakdown): записи, из которых сложилась каждая сторона, с дельтой
-- и стороной после записи. Стартовый долг: компания должна мне 5 000, я должен компании 3 000.
select pg_temp.scenario(7, 300000, p_owe_me => 500000);
select pg_temp.account('H1', 10000000);
select pg_temp.account('KS');
select pg_temp.expense('H1', 'work', 2000000);                          -- компания должна мне +20 000
select pg_temp.topup('H1', 5000000, 100000, 'own');                      -- комиссия своими гасит мой долг 1 000
select pg_temp.expense('H1', 'personal', 1000000, 'company', '2026-11-03'); -- я должен компании +10 000
select pg_temp.transfer('H1', 'KS', 'take_advance', 500000);             -- взял из аванса себе +5 000
select pg_temp.transfer('KS', 'H1', 'repay_debt', 400000);               -- погашение долга в аванс −4 000
select pg_temp.settle('i_paid_company', 'KS', 200000, '2026-11-04');     -- я отдал компании −2 000
select pg_temp.settle('company_paid_me', 'H1', 300000, '2026-11-04');    -- компания отдала мне −3 000
select pg_temp.net(100000, '2026-11-05');                                -- взаимозачёт −1 000 с обеих
select results_eq(
  $$ select type::text, title, delta_minor, side_after_minor from public.v_settlement_breakdown
     where side = 'company_owes_me' order by occurred_on, seq $$,
  $$ values ('adjustment', 'Стартовый долг'::text, 500000::bigint, 500000::bigint),
            ('expense', null, 2000000, 2500000),
            ('settlement', null, -300000, 2200000),
            ('netting', null, -100000, 2100000) $$,
  'breakdown of «компания должна мне»: opening debt, work expense, repayment, взаимозачёт');
select results_eq(
  $$ select type::text, coalesce(transfer_purpose::text, settlement_direction::text), delta_minor, side_after_minor
     from public.v_settlement_breakdown where side = 'i_owe_company' order by occurred_on, seq $$,
  $$ values ('adjustment', null::text, 300000::bigint, 300000::bigint),
            ('company_topup', null, -100000, 200000),
            ('expense', null, 1000000, 1200000),
            ('transfer', 'take_advance', 500000, 1700000),
            ('transfer', 'repay_debt', -400000, 1300000),
            ('settlement', 'i_paid_company', -200000, 1100000),
            ('netting', null, -100000, 1000000) $$,
  'breakdown of «я должен компании»: opening debt, fee offset, expense, transfers, repayment, взаимозачёт');
select results_eq(
  $$ select side::text, sum(delta_minor)::bigint from public.v_settlement_breakdown group by side order by side $$,
  $$ select * from (values ('company_owes_me', (select company_owes_me_minor from public.v_company_settlement)),
                           ('i_owe_company', (select i_owe_company_minor from public.v_company_settlement))) v
     order by 1 $$,
  'each side of the breakdown adds up to the side on «Расчёт с компанией»');
select results_eq(
  $$ select account_name, category_name, purpose::text from public.v_settlement_breakdown
     where type = 'expense' order by occurred_on $$,
  $$ values ('H1'::text, 'Реклама'::text, 'work'::text), ('H1', 'Реклама', 'personal') $$,
  'breakdown rows name the account and category of the entry');
select ok(pg_temp.invariants_hold(), 'breakdown scenario: invariants hold');

reset role;
select pg_temp.login_as_stranger();
select is((select count(*) from public.v_settlement_breakdown), 0::bigint,
  'not allowed: the breakdown is empty');
select throws_ok($$ select pg_temp.net(100) $$, '42501', 'not_allowed', 'not allowed: взаимозачёт cannot be created');
reset role;

select * from finish();
rollback;
