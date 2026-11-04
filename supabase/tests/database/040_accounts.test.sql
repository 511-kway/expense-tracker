-- Счета со стартовым остатком (ADR-0008, док 06 TC-OPENING) и выборка «остатки по счетам».
-- Суммы в тиынах: 1 500 ₸ = 150 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com'),
  ('00000000-0000-0000-0000-00000000000b', 'second@example.com'),
  ('00000000-0000-0000-0000-00000000000c', 'stranger@example.com');
insert into public.app_users (email, user_id, allowed) values
  ('owner@example.com',    '00000000-0000-0000-0000-00000000000a', true),
  ('second@example.com',   '00000000-0000-0000-0000-00000000000b', true),
  ('stranger@example.com', '00000000-0000-0000-0000-00000000000c', false);

create function pg_temp.login_as(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;

-- Ошибка операции как {code, detail}: код в message, подробности JSON в detail.
create function pg_temp.error_of(sql text) returns jsonb language plpgsql as $$
declare v_msg text; v_detail text;
begin
  execute sql;
  return null;
exception when others then
  get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  return jsonb_build_object('code', v_msg, 'detail', nullif(v_detail, '')::jsonb);
end $$;

-- Новый счёт по названию: id из ответа create_account.
create function pg_temp.account_id(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

-- TC-OPENING: setup_start(2026-11-01, owe_me=12000, i_owe=5000);
-- create_account H1 start=2026-11-01 total=150000 company=100000.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select public.setup_start('2026-11-01', 1200000, 500000);
select public.create_account(p_name => 'Халык 1', p_type => 'card', p_bank => 'Halyk', p_mask => '4417',
  p_start_date => '2026-11-01', p_total_minor => 15000000, p_company_minor => 10000000);
select results_eq(
  $$ select balance_minor, advance_minor, own_minor, is_archived from public.v_account_balances
     where name = 'Халык 1' $$,
  $$ values (15000000::bigint, 10000000::bigint, 5000000::bigint, false) $$,
  'TC-OPENING: opening balance and advance are in the account balances, own is the difference');
select results_eq(
  $$ select company_owes_me_minor, i_owe_company_minor, net_minor from public.v_company_settlement $$,
  $$ values (1200000::bigint, 500000::bigint, 700000::bigint) $$,
  'TC-OPENING: opening balance leaves both debt sides and the net as they were');

-- Дата старта счёта не раньше даты начала учёта; счёт не создан.
select is(pg_temp.error_of($$ select public.create_account(p_name => 'Ранний', p_type => 'card',
            p_start_date => '2026-10-31', p_total_minor => 100) $$),
  '{"code": "entry_before_start", "detail": {"start_date": "2026-10-31", "accounting_start_date": "2026-11-01"}}'::jsonb,
  'account start date before the accounting start date: entry_before_start, nothing created');

-- Архив только при нулевых остатке и авансе.
select is(pg_temp.error_of(format('select public.archive_account(%L)', pg_temp.account_id('Халык 1'))),
  jsonb_build_object('code', 'archive_nonzero', 'detail', jsonb_build_object(
    'account_id', pg_temp.account_id('Халык 1'), 'balance_minor', 15000000, 'advance_minor', 10000000)),
  'archive with nonzero balance and advance: archive_nonzero');

select public.create_account(p_name => 'Наличные', p_type => 'cash', p_start_date => '2026-11-02');
select public.archive_account(pg_temp.account_id('Наличные'));
select results_eq($$ select name, is_archived from public.v_account_balances order by name $$,
  $$ values ('Наличные'::text, true), ('Халык 1', false) $$,
  'account with zero balance and advance is archived, history kept');
select public.unarchive_account(pg_temp.account_id('Наличные'));
select is((select is_archived from public.v_account_balances where name = 'Наличные'), false,
  'archived account comes back');

-- Счёт с записями не удалить, только архивировать; без записей удаляется.
select is(pg_temp.error_of(format('select public.delete_account(%L)', pg_temp.account_id('Халык 1'))),
  jsonb_build_object('code', 'account_delete_forbidden', 'detail', jsonb_build_object(
    'account_id', pg_temp.account_id('Халык 1'))),
  'account with entries cannot be deleted: account_delete_forbidden');
select public.delete_account(pg_temp.account_id('Наличные'));
select results_eq($$ select name from public.v_account_balances $$, $$ values ('Халык 1'::text) $$,
  'account without entries is deleted');

-- Правка названия, маски и банка; суммы не меняются.
select public.update_account(pg_temp.account_id('Халык 1'), p_name => 'Halyk Gold', p_bank => 'Halyk Bank',
  p_mask => '0042', p_currency => 'KZT');
select results_eq(
  $$ select name, bank, mask, currency, start_date, balance_minor, advance_minor from public.v_account_balances $$,
  $$ values ('Halyk Gold'::text, 'Halyk Bank'::text, '0042'::text, 'KZT'::text, '2026-11-01'::date,
             15000000::bigint, 10000000::bigint) $$,
  'rename, new mask and bank; start date, balance and advance stay');

-- Валюту счёта с записями не поменять; у счёта без записей можно.
select is(pg_temp.error_of(format(
    $$ select public.update_account(%L, p_name => 'Halyk Gold', p_currency => 'USD') $$,
    pg_temp.account_id('Halyk Gold'))),
  jsonb_build_object('code', 'account_currency_locked', 'detail', jsonb_build_object(
    'account_id', pg_temp.account_id('Halyk Gold'))),
  'currency of an account with entries is locked');
select public.create_account(p_name => 'Лиры', p_type => 'card', p_currency => 'USD', p_start_date => '2026-11-02');
select public.update_account(pg_temp.account_id('Лиры'), p_name => 'Лиры', p_currency => 'TRY');
select is((select currency from public.v_account_balances where name = 'Лиры'), 'TRY',
  'currency of an account without entries can change');

select results_eq($$ select name, has_entries from public.v_account_balances order by name $$,
  $$ values ('Halyk Gold'::text, true), ('Лиры', false) $$,
  'account balances tell which accounts have entries (currency lock, deletion)');

-- Ввод при создании: название уникально, суммы не меньше нуля, компании не больше всего.
select is(pg_temp.error_of($$ select public.create_account(p_name => ' Halyk Gold ', p_type => 'card',
            p_start_date => '2026-11-02') $$),
  '{"code": "account_name_taken", "detail": {"name": "Halyk Gold"}}'::jsonb,
  'accounts differ by name: the same name is rejected');
select is(pg_temp.error_of($$ select public.create_account(p_name => '  ', p_type => 'card') $$),
  '{"code": "missing_required", "detail": {"field": "name"}}'::jsonb, 'name is required');
select is(pg_temp.error_of($$ select public.create_account(p_name => 'Минус', p_type => 'card',
            p_start_date => '2026-11-02', p_total_minor => -1) $$),
  '{"code": "amount_negative", "detail": {}}'::jsonb, 'opening total cannot be negative');
select is(pg_temp.error_of($$ select public.create_account(p_name => 'Перебор', p_type => 'card',
            p_start_date => '2026-11-02', p_total_minor => 100, p_company_minor => 101) $$),
  '{"code": "opening_advance_too_big", "detail": {"total_minor": 100, "company_minor": 101}}'::jsonb,
  'company part cannot exceed the total');
select is(pg_temp.error_of($$ select public.create_account(p_name => 'Доллары', p_type => 'card', p_currency => 'USD',
            p_start_date => '2026-11-02', p_total_minor => 100) $$),
  '{"code": "foreign_opening_not_supported", "detail": {"currency": "USD"}}'::jsonb,
  'opening balance of a non-tenge account waits for currency support');

-- Свои деньги как разница в форме считает сервер, с теми же проверками, что и создание.
select is(public.preview_account_opening(p_total_minor => 15000000, p_company_minor => 10000000),
  '{"own_minor": 5000000}'::jsonb, 'opening preview: own is total minus company');
select is(pg_temp.error_of($$ select public.preview_account_opening(p_total_minor => 1, p_company_minor => 2) $$) ->> 'code',
  'opening_advance_too_big', 'opening preview rejects the same input as create_account');

-- Владельца у счёта нет, дата старта неизменна: прямой записи в счета у клиента нет.
select hasnt_column('public', 'accounts', 'owner', 'accounts have no owner field');
select throws_ok(format($$ update public.accounts set start_date = '2026-11-05' where id = %L $$,
    pg_temp.account_id('Halyk Gold')), '42501', null,
  'account start date cannot be changed by the client');
select throws_ok($$ insert into public.accounts (name, type, start_date) values ('X', 'card', '2026-11-02') $$,
  '42501', null, 'client cannot insert accounts directly');

-- Полный пересчёт даёт те же остатки.
select public.recompute();
select results_eq($$ select balance_minor, advance_minor, own_minor from public.v_account_balances
                     where name = 'Halyk Gold' $$,
  $$ values (15000000::bigint, 10000000::bigint, 5000000::bigint) $$, 'recompute: same opening balance');
reset role;

-- Корректировка остатка в минус с авансом: аванс не уходит в минус (док 03, 4.7).
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select public.create_entry(jsonb_build_object(
  'type', 'adjustment', 'occurred_on', '2026-11-03', 'amount_minor', 12000000,
  'account_id', (select id from public.accounts where name = 'Halyk Gold'),
  'adjustment_sign', -1, 'adjustment_mode', 'plug_hidden', 'adjustment_affects_advance', true));
select results_eq($$ select balance_minor, advance_minor, own_minor from public.v_account_balances
                     where name = 'Halyk Gold' $$,
  $$ values (3000000::bigint, 0::bigint, 3000000::bigint) $$,
  'balance adjustment −120 000 ₸ with advance: balance down by the full sum, advance stops at zero');
reset role;

-- Чужие счета не видны и не трогаются.
select set_config('test.halyk', (select id::text from public.accounts where name = 'Halyk Gold'), true);
select pg_temp.login_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*) from public.v_account_balances), 0::bigint, 'other user sees no accounts');
select is((select count(*) from public.accounts), 0::bigint, 'other user reads no account rows');
select is(pg_temp.error_of(format('select public.archive_account(%L)',
    current_setting('test.halyk'))) ->> 'code',
  'account_not_found', 'other user cannot archive someone else''s account');
select is(pg_temp.error_of($$ select public.create_account(p_name => 'Kaspi', p_type => 'card') $$) ->> 'code',
  'start_not_set', 'account before the first run: start_not_set');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.create_account(p_name => 'Kaspi', p_type => 'card') $$, '42501', 'not_allowed',
  'not allowed: create_account raises not_allowed');
reset role;

select * from finish();
rollback;
