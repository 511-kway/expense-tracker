-- Первый запуск и стартовый долг (ADR-0008, док 06 TC-OPENING) и выборка «расчёт с компанией».
-- Суммы в тиынах: 12 000 ₸ = 1 200 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

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

create function pg_temp.settlement() returns table (owe_me bigint, i_owe bigint, net bigint)
language sql as $$
  select company_owes_me_minor, i_owe_company_minor, net_minor from public.v_company_settlement
$$;

-- TC-OPENING: стартовый долг виден в выборке, итог = разница сторон.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select public.setup_start('2026-11-01', 1200000, 500000);
select results_eq(
  $$ select company_owes_me_minor, i_owe_company_minor, net_minor from public.v_company_settlement $$,
  $$ values (1200000::bigint, 500000::bigint, 700000::bigint) $$,
  'opening debt: both sides and net with the company come from the ledger');

select results_eq(
  $$ select accounting_start_date, timezone, default_currency from public.user_settings $$,
  $$ values ('2026-11-01'::date, 'Asia/Almaty'::text, 'KZT'::text) $$,
  'first run fixes the accounting start date, Asia/Almaty and KZT');

-- Повторный первый запуск отклонён, ничего не изменилось.
select throws_ok($$ select public.setup_start('2026-10-01', 1, 1) $$, 'P0001', 'start_already_set',
  'second first run: start_already_set');
select results_eq($$ select * from pg_temp.settlement() $$,
  $$ values (1200000::bigint, 500000::bigint, 700000::bigint) $$,
  'second first run changed nothing');
select is((select accounting_start_date from public.user_settings), '2026-11-01'::date,
  'accounting start date did not move');

-- Полный пересчёт идемпотентен.
select public.recompute();
select public.recompute();
select results_eq($$ select * from pg_temp.settlement() $$,
  $$ values (1200000::bigint, 500000::bigint, 700000::bigint) $$,
  'recompute twice: same sides and net');

-- Клиент не пишет записи, журнал и настройки напрямую.
select throws_ok($$ insert into public.entries (type, occurred_on, amount_minor, amount_kzt_minor)
                    values ('income', '2026-11-02', 100, 100) $$, '42501', null,
  'client cannot insert entries directly');
select throws_ok($$ delete from public.ledger_entries $$, '42501', null,
  'client cannot change the ledger directly');
select throws_ok($$ update public.user_settings set accounting_start_date = '2026-01-01' $$, '42501', null,
  'client cannot move the accounting start date directly');
reset role;

-- Второй пользователь: свой итог, чужого стартового долга не видит.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000b');
select results_eq($$ select * from pg_temp.settlement() $$,
  $$ values (0::bigint, 0::bigint, 0::bigint) $$,
  'other user sees zero sides before own first run');
select throws_ok($$ select public.setup_start('2026-11-01', -1, 0) $$, 'P0001', 'amount_negative',
  'opening debt side cannot be negative');
select results_eq($$ select public.setup_start('2026-11-03', 0, 0) ->> 'ok' $$, $$ values ('true') $$,
  'both sides may be zero');
select results_eq($$ select * from pg_temp.settlement() $$,
  $$ values (0::bigint, 0::bigint, 0::bigint) $$,
  'zero opening debt: zero sides and net');
reset role;

-- Без отметки «разрешён» первый запуск недоступен.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.setup_start('2026-11-01', 100, 0) $$, '42501', 'not_allowed',
  'not allowed: setup_start raises not_allowed');
reset role;

-- Пересчёт идёт по дате, затем времени (пустое последним), времени создания, номеру вставки;
-- черновики не входят. Учтённые записи здесь фикстура от postgres: create_entry сразу отклонил бы
-- минус, вставленный раньше плюса (так и надо, но порядок ввода тогда не проверить). Черновик
-- настоящий, из быстрого ввода: личная трата 3 000 ₸ со счёта с авансом ждёт «источник?».
-- У владельца сейчас «я должен компании» = 5 000 ₸.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select public.create_account(p_name => 'H1', p_type => 'card', p_start_date => '2026-11-01',
  p_total_minor => 1000000, p_company_minor => 500000);
select is(public.quick_capture(jsonb_build_object('occurred_on', '2026-11-02', 'amount_minor', 300000,
    'account_id', (select account_id from public.v_account_balances where name = 'H1'),
    'purpose', 'personal', 'title', 'Такси')) ->> 'status',
  'draft', 'quick personal expense on an account with advance waits as a draft');
reset role;
insert into public.entries (user_id, type, status, occurred_on, occurred_at, created_at, amount_minor,
                            amount_kzt_minor, adjustment_mode, adjustment_sign, adjustment_target, in_analytics)
values
  -- вставлена раньше, но датой позже: −8 000 ₸ возможен только после +5 000 ₸ от 03.11
  ('00000000-0000-0000-0000-00000000000a', 'adjustment', 'done', '2026-11-04', null, now(), 800000,
   800000, 'plug_hidden', -1, 'i_owe_company', false),
  ('00000000-0000-0000-0000-00000000000a', 'adjustment', 'done', '2026-11-03', null, now(), 500000,
   500000, 'plug_hidden', 1, 'i_owe_company', false);
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select public.recompute();
select results_eq($$ select * from pg_temp.settlement() $$,
  $$ values (1200000::bigint, 200000::bigint, 1000000::bigint) $$,
  'replay follows the real date, not the input order');
select is((select balance_minor from public.v_account_balances where name = 'H1'), 1000000::bigint,
  'replay leaves the draft out');
reset role;

-- Одна дата 05.11: запись со временем идёт раньше записи без времени, даже если создана позже.
-- Минус на всю сторону до прихода плюса уводит сторону в минус: ошибка с id записи изнутри пересчёта.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select public.create_entry(jsonb_build_object('type', 'adjustment', 'occurred_on', '2026-11-05',
  'amount_minor', 100000, 'adjustment_target', 'i_owe_company', 'adjustment_sign', 1));
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-05', 'occurred_at', '2026-11-05T10:00:00+05:00', 'amount_minor', 300000,
    'adjustment_target', 'i_owe_company', 'adjustment_sign', -1)) $$) #- '{detail,entry_id}',
  '{"code": "debt_below_zero", "detail": {"side": "i_owe_company", "occurred_on": "2026-11-05", "available_minor": 200000, "amount_minor": 300000}}'::jsonb,
  'debt side cannot go below zero: the timed entry replays before the untimed one of the same day');
select results_eq($$ select * from pg_temp.settlement() $$,
  $$ values (1200000::bigint, 300000::bigint, 900000::bigint) $$,
  'failed entry left the ledger as it was');
reset role;

select * from finish();
rollback;
