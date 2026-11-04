-- Переводы между своими счетами (док 03, 4.5 и 8; ADR-0006; док 06, раздел 4; spec.md: без
-- «пополнил аванс переводом»). Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(44);

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

-- TC-MOVE-OWN: income KS 50000; transfer move_own KS→H1 50000.
select pg_temp.scenario(1);
select pg_temp.account('KS');
select pg_temp.account('H1');
select pg_temp.income('KS', 5000000);
select pg_temp.transfer('KS', 'H1', 'move_own', 5000000);
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (0::bigint, 0::bigint, 5000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'TC-MOVE-OWN: перевод своих moves only the balance');

-- TC-MOVE-COMPANY: topup KP 60000; transfer move_company KP→H1 60000.
select pg_temp.scenario(2);
select pg_temp.account('KP');
select pg_temp.account('H1');
select pg_temp.topup('KP', 6000000);
select pg_temp.transfer('KP', 'H1', 'move_company', 6000000);
select results_eq($$ select * from pg_temp.state2('KP', 'H1') $$,
  $$ values (0::bigint, 0::bigint, 6000000::bigint, 6000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-MOVE-COMPANY: перекладка аванса moves the advance with the money, the debt does not move');

-- TC-MOVE-COMPANY-PARTIAL: topup KP 40000; transfer move_company KP→H1 60000 (20000 свои).
select pg_temp.scenario(3);
select pg_temp.account('KP', 2000000);
select pg_temp.account('H1');
select pg_temp.topup('KP', 4000000);
select pg_temp.transfer('KP', 'H1', 'move_company', 6000000);
select results_eq($$ select * from pg_temp.state2('KP', 'H1') $$,
  $$ values (0::bigint, 0::bigint, 6000000::bigint, 4000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-MOVE-COMPANY-PARTIAL: only the advance there is moves, the rest is own money');
select ok(pg_temp.invariants_hold(), 'TC-MOVE-COMPANY-PARTIAL: invariants hold');

-- TC-TAKE-ADVANCE: topup H1 100000; transfer take_advance H1→KS 30000.
select pg_temp.scenario(4);
select pg_temp.account('H1');
select pg_temp.account('KS');
select pg_temp.topup('H1', 10000000);
select pg_temp.transfer('H1', 'KS', 'take_advance', 3000000);
select results_eq($$ select * from pg_temp.state2('H1', 'KS') $$,
  $$ values (7000000::bigint, 7000000::bigint, 3000000::bigint, 0::bigint, 0::bigint, 3000000::bigint) $$,
  'TC-TAKE-ADVANCE: взял из аванса себе turns company money into mine and adds to «я должен компании»');

-- Взял из аванса себе больше аванса: в долг идёт только аванс, остальное свои.
select pg_temp.transfer('H1', 'KS', 'take_advance', 8000000);
select results_eq($$ select * from pg_temp.state2('H1', 'KS') $$,
  $$ values (-1000000::bigint, 0::bigint, 11000000::bigint, 0::bigint, 0::bigint, 10000000::bigint) $$,
  'взял из аванса себе above the advance: only the advance there is becomes debt');
select ok(pg_temp.invariants_hold(), 'TC-TAKE-ADVANCE: invariants hold');

-- TC-TRANSFER-REPAY: topup H1 100000; expense personal H1 30000 source=company (i_owe=30000,
-- adv=70000); transfer repay_debt KS→H1 30000.
select pg_temp.scenario(5);
select pg_temp.account('KS');
select pg_temp.account('H1');
select pg_temp.topup('H1', 10000000);
select set_config('test.debt', pg_temp.expense('H1', 'personal', 3000000, 'company') ->> 'entry_id', true);
select set_config('test.repay', pg_temp.transfer('KS', 'H1', 'repay_debt', 3000000)::text, true);
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 10000000::bigint, 10000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-TRANSFER-REPAY: погашение долга в аванс makes my money advance and pays off «я должен компании»');
select is(current_setting('test.repay')::jsonb -> 'warnings',
  jsonb_build_array(jsonb_build_object('code', 'negative_balance',
    'entry_id', current_setting('test.repay')::jsonb ->> 'entry_id', 'occurred_on', '2026-11-03',
    'account_id', pg_temp.acc('KS'), 'balance_minor', -3000000)),
  'the transfer warns that «откуда» went below zero');
select ok(pg_temp.invariants_hold(), 'TC-TRANSFER-REPAY: invariants hold');

-- TC-REPAY-CAP: погашение долга в аванс больше долга отклоняется, состояние не меняется.
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'H1', 'repay_debt', 1) $$) ->> 'code',
  'debt_overpay', 'TC-REPAY-CAP: repaying more than «я должен компании» is rejected');
select pg_temp.expense('H1', 'personal', 3000000, 'company', '2026-11-04');
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'H1', 'repay_debt', 5000000, p_date => '2026-11-05') $$)
    #- '{detail,entry_id}',
  '{"code": "debt_overpay", "detail": {"occurred_on": "2026-11-05", "side": "i_owe_company",
    "available_minor": 3000000, "amount_minor": 5000000}}'::jsonb,
  'TC-REPAY-CAP: 50 000 at a debt of 30 000 is rejected with the debt on that date');
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 7000000::bigint, 7000000::bigint, 0::bigint, 3000000::bigint) $$,
  'TC-REPAY-CAP: the state did not change');

-- Задним числом: долг берётся на дату записи. 01.11 долга ещё нет (он с 02.11).
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'H1', 'repay_debt', 3000000, p_date => '2026-11-01') $$)
    #- '{detail,entry_id}',
  '{"code": "debt_overpay", "detail": {"occurred_on": "2026-11-01", "side": "i_owe_company",
    "available_minor": 0, "amount_minor": 3000000}}'::jsonb,
  'a backdated repayment cannot pay off a debt that appeared later');
-- Погашение 02.11 после траты влезает в долг, но тогда погашение 03.11 станет больше долга.
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'H1', 'repay_debt', 3000000, p_date => '2026-11-02') $$)
    -> 'detail' ->> 'entry_id', current_setting('test.repay')::jsonb ->> 'entry_id',
  'a backdated repayment that eats the debt makes the later repayment the conflict');
-- Удаление траты, из которой сложился долг, сделало бы прошлое погашение больше долга.
select is(pg_temp.error_of(format('select public.delete_entry(%L)', current_setting('test.debt'))),
  jsonb_build_object('code', 'debt_overpay', 'detail', jsonb_build_object(
    'entry_id', current_setting('test.repay')::jsonb ->> 'entry_id', 'occurred_on', '2026-11-03',
    'side', 'i_owe_company', 'available_minor', 0, 'amount_minor', 3000000)),
  'backdated delete of the debt: the later repayment would exceed it, the repayment is named');
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'expense',
    'occurred_on', '2026-11-02', 'amount_minor', 1000000, 'account_id', %L, 'purpose', 'personal',
    'source', 'company', 'category_id', (select id from public.categories))) $$,
    current_setting('test.debt'), pg_temp.acc('H1'))) -> 'detail' ->> 'entry_id',
  current_setting('test.repay')::jsonb ->> 'entry_id', 'backdated edit of the debt below the repayment is rejected');
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 7000000::bigint, 7000000::bigint, 0::bigint, 3000000::bigint) $$,
  'after the rejected changes the state is as it was');

-- Комиссия перевода, платит компания: съедает аванс «откуда». topup H1 100000;
-- перевод своих H1→KS 30000 с комиссией 500.
select pg_temp.scenario(6);
select pg_temp.account('H1');
select pg_temp.account('KS');
select pg_temp.topup('H1', 10000000);
select pg_temp.transfer('H1', 'KS', 'move_own', 3000000, 50000, 'company');
select results_eq($$ select * from pg_temp.state2('H1', 'KS') $$,
  $$ values (6950000::bigint, 9950000::bigint, 3000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'fee paid by the company: it eats the advance of «откуда», the debt does not move');

-- Комиссия перевода, плачу я: только остаток «откуда».
select pg_temp.scenario(7);
select pg_temp.account('H1');
select pg_temp.account('KS');
select pg_temp.topup('H1', 10000000);
select pg_temp.transfer('H1', 'KS', 'move_own', 3000000, 50000, 'own');
select results_eq($$ select * from pg_temp.state2('H1', 'KS') $$,
  $$ values (6950000::bigint, 10000000::bigint, 3000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'fee paid by me: only the balance of «откуда», advance and debt do not move');

-- Комиссия компании при перекладке аванса: сначала комиссия съедает аванс, переезжает остаток.
-- topup KP 60000; перекладка KP→H1 60000 с комиссией 1000 (на KP было ещё 1000 своих).
select pg_temp.scenario(8);
select pg_temp.account('KP', 100000);
select pg_temp.account('H1');
select pg_temp.topup('KP', 6000000);
select pg_temp.transfer('KP', 'H1', 'move_company', 6000000, 100000, 'company');
select results_eq($$ select * from pg_temp.state2('KP', 'H1') $$,
  $$ values (0::bigint, 0::bigint, 6000000::bigint, 5900000::bigint, 0::bigint, 0::bigint) $$,
  'fee paid by the company on перекладка аванса: the fee eats the advance first, the rest of it moves');
select ok(pg_temp.invariants_hold(), 'fees: invariants hold');

-- Комиссия компании больше аванса: аванс до нуля, нехватка из своих, долг не трогается.
select pg_temp.scenario(9);
select pg_temp.account('H1', 1000000, 20000);
select pg_temp.account('KS');
select pg_temp.transfer('H1', 'KS', 'move_own', 500000, 50000, 'company');
select results_eq($$ select * from pg_temp.state2('H1', 'KS') $$,
  $$ values (450000::bigint, 0::bigint, 500000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'fee paid by the company above the advance: the advance stops at zero');

-- Проверки перевода (док 03, раздел 8; spec.md, история 16).
reset role;
select set_config('test.foreign', (select id::text from public.accounts
  where user_id = '00000000-0000-0000-0000-000000000001' limit 1), true);
select pg_temp.scenario(10);
select pg_temp.account('KS', 1000000);
select pg_temp.account('H1');
select pg_temp.account('Поздний', p_start => '2026-11-10');
select public.create_account(p_name => 'Долларовый', p_type => 'card', p_currency => 'USD',
  p_start_date => '2026-11-01');
-- TC-SAME-ACCOUNT: transfer KS→KS 1000.
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'KS', 'move_own', 100000) $$) ->> 'code',
  'same_account_transfer', 'TC-SAME-ACCOUNT: a transfer to the same account is rejected');
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'Долларовый', 'move_own', 100000) $$) ->> 'code',
  'cross_currency_transfer', 'a transfer between accounts in different currencies is rejected');
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'Поздний', 'move_own', 100000, p_date => '2026-11-05') $$),
  jsonb_build_object('code', 'entry_before_start', 'detail', jsonb_build_object(
    'occurred_on', '2026-11-05', 'account_id', pg_temp.acc('Поздний'), 'start_date', '2026-11-10')),
  'a transfer before the start date of «куда» is rejected');
select is(pg_temp.error_of($$ select pg_temp.transfer('Поздний', 'KS', 'move_own', 100000, p_date => '2026-11-05') $$)
    -> 'detail' ->> 'account_id', pg_temp.acc('Поздний')::text,
  'a transfer before the start date of «откуда» is rejected');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'transfer',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'account_id', pg_temp.acc('KS'),
    'transfer_purpose', 'move_own')) $$),
  '{"code": "missing_required", "detail": {"field": "to_account_id"}}'::jsonb, 'a transfer needs «куда»');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'transfer',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'account_id', pg_temp.acc('KS'),
    'to_account_id', pg_temp.acc('H1'))) $$),
  '{"code": "missing_required", "detail": {"field": "transfer_purpose"}}'::jsonb, 'a transfer needs a purpose');
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'H1', 'top_up_advance', 100000) $$),
  '{"code": "field_invalid", "detail": {"field": "transfer_purpose"}}'::jsonb,
  'there is no purpose «пополнил аванс переводом»');
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'H1', 'move_own', 100000, 500) $$),
  '{"code": "missing_required", "detail": {"field": "fee_payer"}}'::jsonb, 'a fee needs a payer');
select is(pg_temp.error_of($$ select pg_temp.transfer('KS', 'H1', 'move_own', 100000, -1, 'own') $$),
  '{"code": "amount_negative", "detail": {"field": "fee_minor"}}'::jsonb, 'the fee cannot be negative');
select is((select count(*) from public.entries where type = 'transfer'), 0::bigint,
  'rejected transfers are not created');

-- Без комиссии плательщик не хранится; лента показывает обе стороны перевода.
select set_config('test.move', pg_temp.transfer('KS', 'H1', 'move_own', 400000, 0, 'own') ->> 'entry_id', true);
select results_eq(
  $$ select type::text, transfer_purpose::text, account_name, to_account_name, balance_delta_minor,
            advance_delta_minor, to_balance_delta_minor, to_advance_delta_minor, fee_minor, fee_payer::text
     from public.v_entries where type = 'transfer' $$,
  $$ values ('transfer', 'move_own', 'KS'::text, 'H1'::text, -400000::bigint, 0::bigint, 400000::bigint,
             0::bigint, 0::bigint, null::text) $$,
  'entries feed: the transfer with what it did to «откуда» and «куда»');

-- Правка: смена «куда» и назначения; смена типа очищает поля перевода.
select public.update_entry(current_setting('test.move')::uuid, jsonb_build_object('type', 'transfer',
  'occurred_on', '2026-11-03', 'amount_minor', 400000, 'account_id', pg_temp.acc('H1'),
  'to_account_id', pg_temp.acc('KS'), 'transfer_purpose', 'move_own'));
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (1400000::bigint, 0::bigint, -400000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'edit of a transfer: the direction is replaced, not added');
select public.update_entry(current_setting('test.move')::uuid, jsonb_build_object('type', 'income',
  'occurred_on', '2026-11-03', 'amount_minor', 400000, 'account_id', pg_temp.acc('KS'),
  'to_account_id', pg_temp.acc('H1'), 'transfer_purpose', 'move_own'));
select results_eq($$ select type::text, to_account_id, transfer_purpose::text from public.v_entries
                     where entry_id = current_setting('test.move')::uuid $$,
  $$ values ('income', null::uuid, null::text) $$, 'edit to another type clears «куда» and the purpose');
select ok(pg_temp.invariants_hold(), 'checks: invariants hold');

-- Чужой счёт в «куда» не виден так же, как несуществующий.
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'transfer',
    'occurred_on', '2026-11-03', 'amount_minor', 100, 'account_id', %L, 'to_account_id', %L,
    'transfer_purpose', 'move_own')) $$, pg_temp.acc('KS'),
    current_setting('test.foreign'))) ->> 'code',
  'account_not_found', 'a transfer to another user''s account is rejected');

-- Форме погашения долга в аванс долг на дату отдаёт сервер (как advance_on_date изъятию).
select pg_temp.scenario(11, 2000000);
select pg_temp.account('KS');
select pg_temp.account('H1', 5000000, 5000000);
select pg_temp.expense('H1', 'personal', 1000000, 'company', '2026-11-05');
select is(public.debt_on_date('2026-11-04'), '{"company_owes_me_minor": 0, "i_owe_company_minor": 2000000}'::jsonb,
  'debt on a date before the expense: the opening debt only');
select is(public.debt_on_date('2026-11-05'), '{"company_owes_me_minor": 0, "i_owe_company_minor": 3000000}'::jsonb,
  'debt on the date of the expense: a new entry goes after it');
select set_config('test.repay', pg_temp.transfer('KS', 'H1', 'repay_debt', 3000000, p_date => '2026-11-05') ->> 'entry_id', true);
select is(public.debt_on_date('2026-11-05', current_setting('test.repay')::uuid) ->> 'i_owe_company_minor', '3000000',
  'on edit the repayment itself is not counted');
select results_eq($$ select * from pg_temp.state2('KS', 'H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 7000000::bigint, 7000000::bigint, 0::bigint, 0::bigint) $$,
  'погашение долга в аванс pays off the opening debt too');

reset role;
select pg_temp.login_as_stranger();
select throws_ok($$ select public.debt_on_date('2026-11-05') $$, '42501', 'not_allowed',
  'not allowed: debt_on_date raises not_allowed');
select throws_ok($$ select public.create_entry('{"type": "transfer"}') $$, '42501', 'not_allowed',
  'not allowed: a transfer cannot be created');
reset role;

select * from finish();
rollback;
