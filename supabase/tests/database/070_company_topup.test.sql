-- Пополнение от компании и изъятие аванса (док 03, 4.3 и 4.4; ADR-0003, ADR-0006; док 06,
-- разделы 3, 6 и 9). Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(45);

-- Каждый сценарий у своего пользователя: чистый учёт с 01.11.2026, категория «Реклама».
create function pg_temp.scenario(p_n int, p_i_owe bigint default 0) returns void language plpgsql as $$
declare v_uid uuid := ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (v_uid, 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', v_uid, true);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform public.setup_start('2026-11-01', 0, p_i_owe);
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

-- TC-TOPUP-1: topup H1 landed=100000 fee=0.
select pg_temp.scenario(1);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 10000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-TOPUP-1: the top-up lands on the balance and becomes advance');

select ok(pg_temp.invariants_hold(), 'TC-TOPUP-1: invariants hold');
select results_eq(
  $$ select type::text, account_name, balance_delta_minor, advance_delta_minor, company_owes_me_delta_minor,
            i_owe_company_delta_minor, fee_minor, fee_payer::text from public.v_entries where type = 'company_topup' $$,
  $$ values ('company_topup', 'H1'::text, 10000000::bigint, 10000000::bigint, 0::bigint, 0::bigint, 0::bigint,
             null::text) $$,
  'entries feed: the top-up with what it did to the counters');

-- TC-TOPUP-FEE-OWN: income H1 10000; topup H1 landed=100000 fee=500 fee_payer=own.
select pg_temp.scenario(2);
select pg_temp.account('H1');
select pg_temp.income('H1', 1000000);
select pg_temp.topup('H1', 10000000, 50000, 'own');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10950000::bigint, 10000000::bigint, 50000::bigint, 0::bigint) $$,
  'TC-TOPUP-FEE-OWN: the fee comes from own money and becomes «компания должна мне»');
select is((select net_minor from public.v_company_settlement), 50000::bigint, 'TC-TOPUP-FEE-OWN: net is +500');
select ok(pg_temp.invariants_hold(), 'TC-TOPUP-FEE-OWN: invariants hold');

-- TC-TOPUP-FEE-OWN-OFFSET: topup H1 100000; expense personal H1 300 source=company; income H1 10000;
-- topup H1 landed=50000 fee=500 fee_payer=own.
select pg_temp.scenario(3);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select pg_temp.expense('H1', 'personal', 30000, 'company');
select pg_temp.income('H1', 1000000);
select pg_temp.topup('H1', 5000000, 50000, 'own');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (15920000::bigint, 14970000::bigint, 20000::bigint, 0::bigint) $$,
  'TC-TOPUP-FEE-OWN-OFFSET: the fee refund first pays off «я должен компании», the rest is owed to me');
select is((select net_minor from public.v_company_settlement), 20000::bigint, 'TC-TOPUP-FEE-OWN-OFFSET: net is +200');
select ok(pg_temp.invariants_hold(), 'TC-TOPUP-FEE-OWN-OFFSET: invariants hold');

-- TC-TOPUP-FEE-OWN-SHORT: topup H1 100000 (свои 0); income H1 300; topup H1 landed=99000 fee=1000 own.
select pg_temp.scenario(4);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select pg_temp.income('H1', 30000);
select pg_temp.topup('H1', 9900000, 100000, 'own');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (19830000::bigint, 19830000::bigint, 30000::bigint, 0::bigint) $$,
  'TC-TOPUP-FEE-OWN-SHORT: own money covers 300, the advance eats the 700 shortfall');
select ok(pg_temp.invariants_hold(), 'TC-TOPUP-FEE-OWN-SHORT: invariants hold');

-- Пример ADR-0003: свои на H1 = 300, i_owe = 600, landed 100 000, комиссия 1 000:
-- остаток +99 000, аванс +99 300, i_owe −300, owe_me 0.
select pg_temp.scenario(5, 60000);
select pg_temp.account('H1');
select pg_temp.income('H1', 30000);
select pg_temp.topup('H1', 10000000, 100000, 'own');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9930000::bigint, 9930000::bigint, 0::bigint, 30000::bigint) $$,
  'ADR-0003 example: own part 300 only reduces «я должен компании», the shortfall is the company''s');
select ok(pg_temp.invariants_hold(), 'ADR-0003 example: invariants hold');

-- Комиссию платила компания: аванс = то, что пришло, долг не меняется.
select pg_temp.scenario(6);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000, 50000, 'company');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 10000000::bigint, 0::bigint, 0::bigint) $$,
  'fee paid by the company: what landed is the advance, the debt does not move');
select results_eq($$ select fee_minor, fee_payer::text from public.v_entries where type = 'company_topup' $$,
  $$ values (50000::bigint, 'company'::text) $$, 'the fee and its payer are stored');

-- Ввод пополнения: плательщик при комиссии, комиссия не больше суммы, не меньше нуля.
select is(pg_temp.error_of($$ select pg_temp.topup('H1', 100000, 500) $$),
  '{"code": "missing_required", "detail": {"field": "fee_payer"}}'::jsonb, 'a fee needs a payer');
select is(pg_temp.error_of($$ select pg_temp.topup('H1', 100000, 100000, 'own') $$),
  '{"code": "fee_too_big", "detail": {"amount_minor": 100000, "fee_minor": 100000}}'::jsonb,
  'fee paid by me must be less than the amount');
select is(pg_temp.error_of($$ select pg_temp.topup('H1', 100000, -1, 'own') $$),
  '{"code": "amount_negative", "detail": {"field": "fee_minor"}}'::jsonb, 'the fee cannot be negative');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'company_topup',
    'occurred_on', '2026-11-02', 'amount_minor', 100)) $$),
  '{"code": "missing_required", "detail": {"field": "account_id"}}'::jsonb, 'a top-up needs an account');
select is((select count(*) from public.entries where type = 'company_topup'), 1::bigint,
  'rejected top-ups are not created');

-- TC-ADV-RETURN: topup H1 100000; company_advance_return H1 60000.
select pg_temp.scenario(7);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select pg_temp.withdraw('H1', 6000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (4000000::bigint, 4000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-ADV-RETURN: the withdrawal takes the advance and the balance, the debt does not move');
select ok(pg_temp.invariants_hold(), 'TC-ADV-RETURN: invariants hold');

-- TC-ADV-RETURN-CAP: изъять больше аванса нельзя.
select is(pg_temp.error_of($$ select pg_temp.withdraw('H1', 4000001) $$) ->> 'code', 'advance_return_too_big',
  'TC-ADV-RETURN-CAP: withdrawing more than the advance is rejected');
select is((select count(*) from public.entries where type = 'company_advance_return'), 1::bigint,
  'TC-ADV-RETURN-CAP: nothing is created');

-- Изъятие не берёт свои деньги: на счёте свои 50 000 и аванс 10 000, изъять 20 000 нельзя.
select pg_temp.scenario(8);
select pg_temp.account('H1', 6000000, 1000000);
select is(pg_temp.error_of($$ select pg_temp.withdraw('H1', 2000000) $$) ->> 'code', 'advance_return_too_big',
  'own money cannot be withdrawn as advance');

-- Изъятие на дату: аванс, который пришёл позже, на более раннюю дату изъять нельзя.
select pg_temp.topup('H1', 5000000, p_date => '2026-11-10');
select is(pg_temp.error_of($$ select pg_temp.withdraw('H1', 2000000, '2026-11-05') $$) ->> 'code',
  'advance_return_too_big', 'the advance of a later date cannot be withdrawn earlier');
select pg_temp.withdraw('H1', 2000000, '2026-11-11');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9000000::bigint, 4000000::bigint, 0::bigint, 0::bigint) $$,
  'after the top-up date it can');
select is(public.advance_on_date(pg_temp.acc('H1'), '2026-11-05'), '{"advance_minor": 1000000}'::jsonb,
  'the withdrawal form sees the advance on its date');

-- TC-BACKDATE-NET: 01.11 work 100000 (аванса нет), 10.11 topup 100000; пополнение введено первым.
select pg_temp.scenario(9);
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000, p_date => '2026-11-10');
select pg_temp.expense('H1', 'work', 10000000, p_date => '2026-11-01');
select results_eq(
  $$ select adv, owe_me, (select net_minor from public.v_company_settlement) from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 10000000::bigint, 10000000::bigint) $$,
  'TC-BACKDATE-NET: the earlier expense could not use the later advance, net does not collapse');
select ok(pg_temp.invariants_hold(), 'TC-BACKDATE-NET: invariants hold');

-- TC-REALDATE-CONSUME: 01.11 topup 100000, 10.11 work 100000 (трата введена первой).
select pg_temp.scenario(10);
select pg_temp.account('H1');
select pg_temp.expense('H1', 'work', 10000000, p_date => '2026-11-10');
select pg_temp.topup('H1', 10000000, p_date => '2026-11-01');
select results_eq($$ select adv, owe_me from pg_temp.state('H1') $$,
  $$ values (0::bigint, 0::bigint) $$,
  'TC-REALDATE-CONSUME: by the real date the expense consumed the advance');

-- Удаление и правка задним числом (ADR-0006): 01.11 topup 100000; 05.11 изъятие 60000.
select pg_temp.scenario(11);
select pg_temp.account('H1');
select set_config('test.topup', pg_temp.topup('H1', 10000000, p_date => '2026-11-01') ->> 'entry_id', true);
select set_config('test.withdraw', pg_temp.withdraw('H1', 6000000, '2026-11-05') ->> 'entry_id', true);
select is(pg_temp.error_of(format('select public.delete_entry(%L)', current_setting('test.topup'))),
  jsonb_build_object('code', 'advance_return_too_big', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.withdraw'), 'occurred_on', '2026-11-05',
    'account_id', pg_temp.acc('H1'), 'advance_minor', 0, 'amount_minor', 6000000)),
  'backdated delete of the top-up: the later withdrawal would exceed the advance, it is named');
select is((select count(*) from public.entries where id = current_setting('test.topup')::uuid), 1::bigint,
  'backdated delete guard: the top-up is not deleted');
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'company_topup',
    'occurred_on', '2026-11-01', 'amount_minor', 5000000, 'account_id', %L)) $$,
    current_setting('test.topup'), pg_temp.acc('H1'))) -> 'detail' ->> 'entry_id',
  current_setting('test.withdraw'), 'backdated edit of the top-up below the withdrawal is rejected the same way');
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'company_topup',
    'occurred_on', '2026-11-06', 'amount_minor', 10000000, 'account_id', %L)) $$,
    current_setting('test.topup'), pg_temp.acc('H1'))) ->> 'code',
  'advance_return_too_big', 'moving the top-up after the withdrawal is rejected');
select is(pg_temp.error_of($$ select pg_temp.withdraw('H1', 5000000, '2026-11-03') $$) -> 'detail' ->> 'entry_id',
  current_setting('test.withdraw'), 'backdated insert of a withdrawal: the later withdrawal is the conflict');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (4000000::bigint, 4000000::bigint, 0::bigint, 0::bigint) $$,
  'after the rejected changes the state is as it was');
select is((select count(*) from public.entries where type in ('company_topup', 'company_advance_return')),
  2::bigint, 'after the rejected changes the entries are as they were');

-- Правка со сменой типа: пополнение с комиссией стало поступлением, поля комиссии очищены.
select public.delete_entry(current_setting('test.withdraw')::uuid);
select public.update_entry(current_setting('test.topup')::uuid, jsonb_build_object('type', 'company_topup',
  'occurred_on', '2026-11-01', 'amount_minor', 10000000, 'account_id', pg_temp.acc('H1'),
  'fee_minor', 50000, 'fee_payer', 'own'));
select public.update_entry(current_setting('test.topup')::uuid, jsonb_build_object('type', 'income',
  'occurred_on', '2026-11-01', 'amount_minor', 10000000, 'account_id', pg_temp.acc('H1'),
  'fee_minor', 50000, 'fee_payer', 'own'));
select results_eq($$ select type::text, fee_minor, fee_payer::text from public.v_entries $$,
  $$ values ('income', 0::bigint, null::text) $$, 'edit to another type clears the fee fields');

-- Три способа ввести комиссию пополнения: суммы считает сервер.
select is(public.topup_amounts('sent_fee', 10000000, 50000, 'own'),
  '{"sent_minor": 10000000, "arrived_minor": 9950000, "fee_minor": 50000, "fee_payer_needed": true, "fee_payer": "own", "amount_minor": 10000000}'::jsonb,
  'sent and fee, fee paid by me: the company credits all it sent');
select is(public.topup_amounts('arrived_fee', 9950000, 50000, 'company'),
  '{"sent_minor": 10000000, "arrived_minor": 9950000, "fee_minor": 50000, "fee_payer_needed": true, "fee_payer": "company", "amount_minor": 9950000}'::jsonb,
  'arrived and fee, fee paid by the company: the advance is what arrived');
select is(public.topup_amounts('sent_arrived', 10000000, 10000000),
  '{"sent_minor": 10000000, "arrived_minor": 10000000, "fee_minor": 0, "fee_payer_needed": false, "fee_payer": null, "amount_minor": 10000000}'::jsonb,
  'sent and arrived equal: no fee, no payer needed');
select is(public.topup_amounts('sent_fee', 10000000, 50000) -> 'amount_minor', 'null'::jsonb,
  'with a fee and no payer yet the amount of the entry is unknown');
select is(pg_temp.error_of($$ select public.topup_amounts('sent_arrived', 100, 200, 'own') $$) ->> 'code',
  'fee_too_big', 'arrived more than sent is rejected');

reset role;
select pg_temp.login_as_stranger();
select throws_ok($$ select public.topup_amounts('sent_fee', 100, 0) $$, '42501', 'not_allowed',
  'not allowed: topup_amounts raises not_allowed');
reset role;

select * from finish();
rollback;
