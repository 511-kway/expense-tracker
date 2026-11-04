-- Трата и поступление (док 03, 4.1 и 4.2; док 06, разделы 3 и 9): общие RPC записей
-- create_entry / update_entry / delete_entry, авто-сплит, задним числом, правка и удаление,
-- запись раньше старта, предупреждения пересчёта и о дубле. Суммы в тиынах: 1 000 ₸ = 100 000.
-- «topup H1 X» из дока 06 здесь заменён стартовым остатком счёта X, все из них компании:
-- пополнение от компании появится в тикете 09, а состояние счёта до траты то же.
begin;
create extension if not exists pgtap with schema extensions;
select plan(52);

-- Каждый сценарий у своего пользователя: чистый учёт с 01.11.2026, категория «Реклама».
create function pg_temp.scenario(p_n int) returns void language plpgsql as $$
declare v_uid uuid := ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (v_uid, 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', v_uid, true);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform public.setup_start('2026-11-01', 0, 0);
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

-- TC-EXP-WORK-WITHIN: topup H1 100000; expense work H1 60000.
select pg_temp.scenario(1);
select pg_temp.account('H1', 10000000, 10000000);
select pg_temp.expense('H1', 'work', 6000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (4000000::bigint, 4000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-EXP-WORK-WITHIN: work expense within the advance takes it from the advance');

select ok(pg_temp.invariants_hold(), 'TC-EXP-WORK-WITHIN: invariants hold');
select results_eq(
  $$ select type::text, purpose::text, source::text, category_name, account_name, balance_delta_minor,
            advance_delta_minor, company_owes_me_delta_minor, i_owe_company_delta_minor from public.v_entries
     where type = 'expense' $$,
  $$ values ('expense', 'work', null::text, 'Реклама'::text, 'H1'::text, -6000000::bigint, -6000000::bigint,
             0::bigint, 0::bigint) $$,
  'entries feed: the expense with its category, account and what it did to the counters');

-- TC-EXP-WORK-SPLIT: topup H1 60000; expense work H1 100000. Остаток в минусе: предупреждение,
-- запись сохранена.
select pg_temp.scenario(2);
select pg_temp.account('H1', 6000000, 6000000);
select set_config('test.result', pg_temp.expense('H1', 'work', 10000000)::text, true);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (-4000000::bigint, 0::bigint, 4000000::bigint, 0::bigint) $$,
  'TC-EXP-WORK-SPLIT: the advance goes to zero, the rest becomes «компания должна мне»');
select ok(pg_temp.invariants_hold(), 'TC-EXP-WORK-SPLIT: invariants hold');
select is(current_setting('test.result')::jsonb -> 'warnings',
  jsonb_build_array(jsonb_build_object('code', 'negative_balance',
    'entry_id', current_setting('test.result')::jsonb ->> 'entry_id', 'occurred_on', '2026-11-02',
    'account_id', pg_temp.acc('H1'), 'balance_minor', -4000000)),
  'balance below zero: a negative_balance warning with the entry and the account, the entry is saved');
select is((current_setting('test.result')::jsonb ->> 'status'), 'done', 'create_entry answers the status');

-- TC-EXP-PERS-COMPANY: topup H1 100000; expense personal H1 30000 source=company.
select pg_temp.scenario(3);
select pg_temp.account('H1', 10000000, 10000000);
select pg_temp.expense('H1', 'personal', 3000000, 'company');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (7000000::bigint, 7000000::bigint, 0::bigint, 3000000::bigint) $$,
  'TC-EXP-PERS-COMPANY: personal with company money: advance down, «я должен компании» up');
select ok(pg_temp.invariants_hold(), 'TC-EXP-PERS-COMPANY: invariants hold');

-- TC-EXP-PERS-COMPANY-SPLIT: topup H1 20000; expense personal H1 50000 source=company.
select pg_temp.scenario(4);
select pg_temp.account('H1', 2000000, 2000000);
select pg_temp.expense('H1', 'personal', 5000000, 'company');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 0::bigint, 2000000::bigint) $$,
  'TC-EXP-PERS-COMPANY-SPLIT: only the spent advance becomes «я должен компании», the rest is own');
select ok(pg_temp.invariants_hold(), 'TC-EXP-PERS-COMPANY-SPLIT: invariants hold');

-- TC-EXP-PERS-OWN: income H1 50000; expense personal H1 20000 source=own.
select pg_temp.scenario(5);
select pg_temp.account('H1');
select pg_temp.income('H1', 5000000);
select pg_temp.expense('H1', 'personal', 2000000, 'own');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (3000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'TC-EXP-PERS-OWN: personal with own money changes only the balance');
select ok(pg_temp.invariants_hold(), 'TC-EXP-PERS-OWN: invariants hold');

-- TC-EXP-OWN-WORK: income H1 50000; expense work H1 20000.
select pg_temp.scenario(6);
select pg_temp.account('H1');
select pg_temp.income('H1', 5000000);
select pg_temp.expense('H1', 'work', 2000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (3000000::bigint, 0::bigint, 2000000::bigint, 0::bigint) $$,
  'TC-EXP-OWN-WORK: work expense without an advance: «компания должна мне» up');
select ok(pg_temp.invariants_hold(), 'TC-EXP-OWN-WORK: invariants hold');

-- TC-INCOME: income KS 250000.
select pg_temp.scenario(7);
select pg_temp.account('KS');
select pg_temp.income('KS', 25000000);
select results_eq($$ select * from pg_temp.state('KS') $$,
  $$ values (25000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'TC-INCOME: income changes only the balance');
select ok(pg_temp.invariants_hold(), 'TC-INCOME: invariants hold');

-- Источник у личной траты спрашивается только со счёта, где на момент траты есть аванс.
select pg_temp.scenario(8);
select pg_temp.account('H1', 10000000, 4000000);
select pg_temp.account('KS', 1000000, 0);
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 100000) $$),
  jsonb_build_object('code', 'source_required', 'detail',
    jsonb_build_object('account_id', pg_temp.acc('H1'), 'advance_minor', 4000000)),
  'personal expense from an account with an advance: source_required');
select pg_temp.expense('KS', 'personal', 100000);
select is((select source::text from public.v_entries where account_name = 'KS' and type = 'expense'), 'own',
  'personal expense from an account without an advance: source is own');
select is(public.expense_source_needed(pg_temp.acc('H1'), '2026-11-02'),
  '{"source_needed": true, "advance_minor": 4000000}'::jsonb, 'the form asks «чьими деньгами» for H1');
select is(public.expense_source_needed(pg_temp.acc('KS'), '2026-11-02'),
  '{"source_needed": false, "advance_minor": 0}'::jsonb, 'the form does not ask for KS');
select pg_temp.expense('H1', 'work', 4000000, p_date => '2026-11-03');
select is(public.expense_source_needed(pg_temp.acc('H1'), '2026-11-03') ->> 'source_needed', 'false',
  'after the advance is spent the question is not needed on that date');
select is(public.expense_source_needed(pg_temp.acc('H1'), '2026-11-02') ->> 'source_needed', 'true',
  'a backdated personal expense before that still needs it');

-- TC-TIEBREAK: одной датой topup H1 50000; expense work H1 30000; expense work H1 40000.
select pg_temp.scenario(9);
select pg_temp.account('H1', 5000000, 5000000);
select pg_temp.expense('H1', 'work', 3000000);
select pg_temp.expense('H1', 'work', 4000000);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (-2000000::bigint, 0::bigint, 2000000::bigint, 0::bigint) $$,
  'TC-TIEBREAK: the second expense of the day gets the rest of the advance, the rest is owed to me');
select public.recompute();
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (-2000000::bigint, 0::bigint, 2000000::bigint, 0::bigint) $$,
  'TC-RECOMPUTE-IDEMPOTENT: recompute again gives the same counters');

-- Задним числом: трата раньше по дате съедает аванс первой и меняет сплит последующей.
-- topup H1 100000 (01.11); work 60000 05.11 (adv 40000); затем work 70000 датой 03.11:
-- 03.11 берёт 70000 из аванса (adv 30000), 05.11 берёт 30000 из аванса и 30000 из своих.
select pg_temp.scenario(10);
select pg_temp.account('H1', 10000000, 10000000);
select pg_temp.expense('H1', 'work', 6000000, p_date => '2026-11-05');
select pg_temp.expense('H1', 'work', 7000000, p_date => '2026-11-03');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (-3000000::bigint, 0::bigint, 3000000::bigint, 0::bigint) $$,
  'backdated expense: replayed by the real date, the later expense now splits');
select results_eq(
  $$ select occurred_on, advance_delta_minor, company_owes_me_delta_minor from public.v_entries
     where type = 'expense' order by occurred_on $$,
  $$ values ('2026-11-03'::date, -7000000::bigint, 0::bigint), ('2026-11-05', -3000000, 3000000) $$,
  'backdated expense: the split of the later expense changed');
select ok(pg_temp.invariants_hold(), 'backdated expense: invariants hold');

-- TC-EDIT-RECOMPUTE: topup H1 100000; expense work H1 60000; правка суммы на 20000.
select pg_temp.scenario(11);
select pg_temp.account('H1', 10000000, 10000000);
select set_config('test.entry', pg_temp.expense('H1', 'work', 6000000) ->> 'entry_id', true);
select public.update_entry(current_setting('test.entry')::uuid, jsonb_build_object(
  'type', 'expense', 'occurred_on', '2026-11-02', 'amount_minor', 2000000, 'account_id', pg_temp.acc('H1'),
  'purpose', 'work', 'category_id', (select id from public.categories), 'comment', 'Таргет'));
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (8000000::bigint, 8000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-EDIT-RECOMPUTE: editing the amount rebuilds the ledger');
select is((select comment from public.v_entries where entry_id = current_setting('test.entry')::uuid), 'Таргет',
  'edit replaces the fields of the entry');

-- Правка меняет тип: трата становится поступлением.
select public.update_entry(current_setting('test.entry')::uuid, jsonb_build_object(
  'type', 'income', 'occurred_on', '2026-11-02', 'amount_minor', 2000000, 'account_id', pg_temp.acc('H1')));
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (12000000::bigint, 10000000::bigint, 0::bigint, 0::bigint) $$,
  'edit with a type change: the expense became income, full rebuild');
select results_eq($$ select type::text, purpose::text, category_id from public.v_entries
                     where entry_id = current_setting('test.entry')::uuid $$,
  $$ values ('income', null::text, null::uuid) $$, 'fields of the old type are cleared');

-- TC-DELETE-RECOMPUTE: удаление пересчитывает.
select public.delete_entry(current_setting('test.entry')::uuid);
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 10000000::bigint, 0::bigint, 0::bigint) $$,
  'TC-DELETE-RECOMPUTE: deleting the entry restores the advance');
select is((select count(*) from public.v_entries where type <> 'adjustment'), 0::bigint, 'the entry is gone');
select ok(pg_temp.invariants_hold(), 'edit and delete: invariants hold');

-- TC-BEFORE-START (ADR-0008): запись раньше даты старта счёта или начала учёта отклоняется.
select pg_temp.scenario(12);
select pg_temp.account('H1', p_start => '2026-11-05');
select is(pg_temp.error_of($$ select pg_temp.income('H1', 100, '2026-11-04') $$),
  jsonb_build_object('code', 'entry_before_start', 'detail', jsonb_build_object(
    'occurred_on', '2026-11-04', 'account_id', pg_temp.acc('H1'), 'start_date', '2026-11-05')),
  'TC-BEFORE-START: entry before the account start date');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'work', 100, p_date => '2026-10-31') $$),
  '{"code": "entry_before_start", "detail": {"occurred_on": "2026-10-31", "accounting_start_date": "2026-11-01"}}'::jsonb,
  'TC-BEFORE-START: entry before the accounting start date');
select set_config('test.entry', pg_temp.income('H1', 100, '2026-11-05') ->> 'entry_id', true);
select is(pg_temp.error_of(format($$ select public.update_entry(%L, jsonb_build_object('type', 'income',
    'occurred_on', '2026-11-04', 'amount_minor', 100, 'account_id', %L)) $$,
    current_setting('test.entry'), pg_temp.acc('H1'))) ->> 'code',
  'entry_before_start', 'edit cannot move the entry before the account start date');
select is((select count(*) from public.entries where type <> 'adjustment'), 1::bigint,
  'rejected entries are not created');

-- Мягкое предупреждение о дубле: та же трата в тот же день; запись сохранена.
select pg_temp.scenario(13);
select pg_temp.account('H1', 1000000, 0);
select set_config('test.first', pg_temp.expense('H1', 'personal', 50000) ->> 'entry_id', true);
select set_config('test.result', pg_temp.expense('H1', 'personal', 50000)::text, true);
select is(current_setting('test.result')::jsonb -> 'warnings',
  jsonb_build_array(jsonb_build_object('code', 'possible_duplicate',
    'entry_id', current_setting('test.result')::jsonb ->> 'entry_id',
    'duplicate_of', current_setting('test.first'), 'occurred_on', '2026-11-02')),
  'the same expense on the same day: possible_duplicate warning');
select is((select count(*) from public.entries where type = 'expense'), 2::bigint, 'the duplicate is still saved');
select is(pg_temp.warning_codes(pg_temp.expense('H1', 'personal', 50000, p_date => '2026-11-03')), '{}'::text[],
  'the same expense on another day: no warning');

-- Ввод: обязательные поля, сумма, валюта, чужие счёт и категория.
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'expense',
    'occurred_on', '2026-11-02', 'amount_minor', 100, 'account_id', pg_temp.acc('H1'), 'purpose', 'work')) $$),
  '{"code": "missing_required", "detail": {"field": "category_id"}}'::jsonb, 'expense needs a category');
select is(pg_temp.error_of($$ select pg_temp.income('H1', 0) $$) ->> 'code', 'amount_not_positive',
  'amount must be above zero');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'income',
    'occurred_on', '2026-11-02', 'amount_minor', 1500.5, 'account_id', pg_temp.acc('H1'))) $$),
  '{"code": "field_invalid", "detail": {"field": "amount_minor"}}'::jsonb,
  'amounts are whole minor units only');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'income',
    'occurred_on', '2026-11-02', 'amount_minor', 100, 'currency', 'USD', 'account_id', pg_temp.acc('H1'))) $$),
  '{"code": "foreign_amount_not_supported", "detail": {"currency": "USD", "account_currency": "KZT"}}'::jsonb,
  'amounts in another currency wait for currency support');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'gift',
    'occurred_on', '2026-11-02', 'amount_minor', 100, 'account_id', pg_temp.acc('H1'))) $$),
  '{"code": "field_invalid", "detail": {"field": "type"}}'::jsonb,
  'an unknown entry type is rejected');
select set_config('test.h1', pg_temp.acc('H1')::text, true);
select set_config('test.entry', current_setting('test.first'), true);

-- Чужие записи: не видны, не меняются; чужой счёт не принимается.
select pg_temp.scenario(14);
select is((select count(*) from public.v_entries), 0::bigint, 'other user sees no entries');
select is(pg_temp.error_of(format('select public.delete_entry(%L)', current_setting('test.entry'))) ->> 'code',
  'entry_not_found', 'other user cannot delete someone else''s entry');
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'income',
    'occurred_on', '2026-11-02', 'amount_minor', 100, 'account_id', %L)) $$, current_setting('test.h1'))) ->> 'code',
  'account_not_found', 'other user cannot write to someone else''s account');
select throws_ok($$ insert into public.entries (type, occurred_on, amount_minor, amount_kzt_minor)
                    values ('income', '2026-11-02', 100, 100) $$, '42501', null,
  'client cannot insert entries directly');

reset role;
select pg_temp.login_as_stranger();
select throws_ok($$ select public.create_entry('{}') $$, '42501', 'not_allowed',
  'not allowed: create_entry raises not_allowed');
reset role;

select * from finish();
rollback;
