-- Экспорт (док 04, раздел 9): выборки, из которых Edge Function `export` строит два файла.
-- v_export_entries: учтённые записи с названиями счетов и категорий, external_id (свой или id записи)
-- и ссылкой возврата на трату по её external_id. v_settlement_movements: одна строка на запись,
-- двигавшую долг, с изменением каждой стороны и обеими сторонами после записи.
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

create function pg_temp.scenario(p_n int, p_i_owe bigint default 0, p_owe_me bigint default 0) returns void
language plpgsql as $$
declare v_uid uuid := ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (v_uid, 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', v_uid, true);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform public.setup_start('2026-11-01', p_owe_me, p_i_owe);
  perform public.create_category('Реклама');
end $$;

create function pg_temp.login_as_stranger() returns void language plpgsql as $$
begin
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000cc', 'stranger@example.com');
  insert into public.app_users (email, user_id, allowed) values ('stranger@example.com', '00000000-0000-0000-0000-0000000000cc', false);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000cc', 'role', 'authenticated')::text, true);
end $$;

create function pg_temp.account(p_name text, p_total bigint default 0, p_company bigint default 0) returns uuid
language sql as $$
  select (public.create_account(p_name => p_name, p_type => 'card', p_start_date => '2026-11-01',
            p_total_minor => p_total, p_company_minor => p_company) ->> 'account_id')::uuid
$$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

create function pg_temp.expense(p_account text, p_purpose text, p_amount bigint, p_source text default null,
                                p_date date default '2026-11-02', p_external_id text default null)
returns jsonb language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'expense', 'occurred_on', p_date, 'amount_minor', p_amount, 'currency', 'KZT',
    'account_id', pg_temp.acc(p_account), 'purpose', p_purpose, 'source', p_source,
    'external_id', p_external_id,
    'category_id', (select id from public.categories where name = 'Реклама'))))
$$;

create function pg_temp.topup(p_account text, p_amount bigint, p_fee bigint default 0, p_payer text default null,
                              p_date date default '2026-11-02') returns jsonb language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'company_topup', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_account), 'fee_minor', p_fee, 'fee_payer', p_payer)))
$$;

create function pg_temp.transfer(p_from text, p_to text, p_purpose text, p_amount bigint, p_fee bigint default 0,
                                 p_payer text default null, p_date date default '2026-11-03') returns jsonb
language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'transfer', 'occurred_on', p_date, 'amount_minor', p_amount,
    'account_id', pg_temp.acc(p_from), 'to_account_id', pg_temp.acc(p_to), 'transfer_purpose', p_purpose,
    'fee_minor', p_fee, 'fee_payer', p_payer)))
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

-- 1. Записи для файла expenses.
select pg_temp.scenario(1);
select pg_temp.account('H1', 10000000, 2000000);   -- стартовый остаток: 80 000 своих и 20 000 аванса
select pg_temp.account('KS');
-- Черновик быстрого ввода: личная трата со счёта с авансом ждёт «источник?».
select public.quick_capture(jsonb_build_object(
  'occurred_on', '2026-11-01', 'amount_minor', 70000, 'account_id', pg_temp.acc('H1'), 'purpose', 'personal', 'title', 'Такси'));
select set_config('test.work', pg_temp.expense('H1', 'work', 2000000) ->> 'entry_id', true);
select pg_temp.expense('H1', 'personal', 150000, 'own', '2026-11-02', 'bank-42');
select pg_temp.transfer('H1', 'KS', 'move_own', 500000, 1000, 'own');
select public.create_entry(jsonb_build_object(
  'type', 'refund', 'occurred_on', '2026-11-05', 'amount_minor', 500000, 'parent_entry_id', current_setting('test.work')));

select results_eq(
  $$ select occurred_on, type::text, account_name, amount_minor, currency, adjustment_target::text,
            adjustment_mode::text, adjustment_sign::int, adjustment_affects_advance, in_analytics, title
     from public.v_export_entries where type = 'adjustment' order by occurred_on, created_at, seq $$,
  $$ values ('2026-11-01'::date, 'adjustment', 'H1'::text, 8000000::bigint, 'KZT'::text, 'balance', 'plug_hidden', 1,
             false, false, 'Стартовый остаток'::text),
            ('2026-11-01', 'adjustment', 'H1', 2000000, 'KZT', 'balance', 'plug_hidden', 1, true, false, 'Стартовый остаток') $$,
  'the opening balance is exported as two adjustments: own money and the company advance');

select results_eq(
  $$ select type::text, account_name, to_account_name, category_name, purpose::text, source::text,
            transfer_purpose::text, amount_minor, fee_minor, fee_payer::text, amount_kzt_minor
     from public.v_export_entries where type <> 'adjustment' order by occurred_on, created_at, seq $$,
  $$ values ('expense', 'H1'::text, null::text, 'Реклама'::text, 'work', null::text, null, 2000000::bigint, 0::bigint, null, 2000000::bigint),
            ('expense', 'H1', null, 'Реклама', 'personal', 'own', null, 150000, 0, null, 150000),
            ('transfer', 'H1', 'KS', null, null, null, 'move_own', 500000, 1000, 'own', 500000),
            ('refund', 'H1', null, 'Реклама', 'work', null, null, 500000, 0, null, 500000) $$,
  'entries carry account, category and the fields of their type, by name');

select is((select count(*) from public.v_export_entries where title = 'Такси'), 0::bigint,
  'a draft from quick capture is not exported: import does not create drafts');

select results_eq(
  $$ select external_id = entry_id::text, external_id from public.v_export_entries
     where type = 'expense' order by occurred_on, created_at, seq $$,
  $$ values (true, current_setting('test.work')), (false, 'bank-42') $$,
  'external_id is the imported one, otherwise the entry id: a re-import of the export is idempotent');

select is((select parent_external_id from public.v_export_entries where type = 'refund'), current_setting('test.work'),
  'a refund points to its expense by the external_id of the expense');

-- 2. Движения с компанией (сценарий разбора долга из 090_settlement). Стартовый долг: компания
-- должна мне 5 000, я должен компании 3 000.
select pg_temp.scenario(2, 300000, p_owe_me => 500000);
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
  $$ select type::text, company_owes_me_delta_minor, i_owe_company_delta_minor,
            company_owes_me_after_minor, i_owe_company_after_minor, net_after_minor
     from public.v_settlement_movements order by occurred_on, occurred_at nulls last, created_at, seq $$,
  $$ values ('adjustment', 500000::bigint, 0::bigint, 500000::bigint, 0::bigint, 500000::bigint),
            ('adjustment', 0, 300000, 500000, 300000, 200000),
            ('expense', 2000000, 0, 2500000, 300000, 2200000),
            ('company_topup', 0, -100000, 2500000, 200000, 2300000),
            ('expense', 0, 1000000, 2500000, 1200000, 1300000),
            ('transfer', 0, 500000, 2500000, 1700000, 800000),
            ('transfer', 0, -400000, 2500000, 1300000, 1200000),
            ('settlement', 0, -200000, 2500000, 1100000, 1400000),
            ('settlement', -300000, 0, 2200000, 1100000, 1100000),
            ('netting', -100000, -100000, 2100000, 1000000, 1100000) $$,
  'one movement per entry: the change of each side and both sides after it, in recompute order');

select results_eq(
  $$ select company_owes_me_after_minor, i_owe_company_after_minor, net_after_minor from public.v_settlement_movements
     order by occurred_on desc, occurred_at desc nulls first, created_at desc, seq desc limit 1 $$,
  $$ select company_owes_me_minor, i_owe_company_minor, net_minor from public.v_company_settlement $$,
  'the sides after the last movement equal «Расчёт с компанией»');

select results_eq(
  $$ select type::text, company_owes_me_after_minor, i_owe_company_after_minor from public.v_settlement_movements
     where occurred_on >= '2026-11-04' order by occurred_on, created_at, seq $$,
  $$ values ('settlement', 2500000::bigint, 1100000::bigint), ('settlement', 2200000, 1100000),
            ('netting', 2100000, 1000000) $$,
  'a period filter keeps the sides after accumulated over the whole history');

select results_eq(
  $$ select account_name, category_name, purpose::text, external_id = entry_id::text, currency
     from public.v_settlement_movements where type = 'expense' order by occurred_on $$,
  $$ values ('H1'::text, 'Реклама'::text, 'work'::text, true, 'KZT'::text), ('H1', 'Реклама', 'personal', true, 'KZT') $$,
  'movements name the account and category and link to the entry by external_id');

reset role;
select pg_temp.login_as_stranger();
select is((select count(*) from public.v_export_entries) + (select count(*) from public.v_settlement_movements),
  0::bigint, 'not allowed: both exports are empty');

select * from finish();
rollback;
