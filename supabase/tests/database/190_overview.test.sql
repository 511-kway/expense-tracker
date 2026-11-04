-- Обзор (spec.md, история 90; док 04, раздел 10; док 05 v_overview): всего денег, свои деньги,
-- деньги компании на картах, итог с компанией, личные траты за период. Все числа из журнала.
-- Ожидаемые суммы посчитаны вручную по сценарию ниже (тиыны и центы: 1 500 ₸ = 150 000).
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

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

create function pg_temp.error_of(sql text) returns jsonb language plpgsql as $$
declare v_msg text; v_detail text;
begin
  execute sql;
  return null;
exception when others then
  get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  return jsonb_build_object('code', v_msg, 'detail', nullif(v_detail, '')::jsonb);
end $$;

-- Курс Нацбанка в кэше (его кладёт Edge Function fetch_rates от service_role).
create function pg_temp.nbk_rate(p_currency text, p_date date, p_rate numeric) returns void
language plpgsql as $$
declare v_role text := current_setting('role');
begin
  perform set_config('role', 'postgres', true);
  insert into public.fx_rates (rate_date, currency, rate) values (p_date, p_currency, p_rate);
  perform set_config('role', v_role, true);
end $$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

create function pg_temp.entry(p jsonb) returns uuid language sql as $$
  select (public.create_entry(p) ->> 'entry_id')::uuid
$$;

create function pg_temp.expense(p_account text, p_purpose text, p_amount bigint, p_date date,
                                p_source text default null, p_in_analytics boolean default null,
                                p_currency text default 'KZT', p_rate text default null) returns uuid
language sql as $$
  select pg_temp.entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'expense', 'occurred_on', p_date, 'amount_minor', p_amount, 'currency', p_currency,
    'rate_source', case when p_rate is not null then 'manual' end, 'rate', p_rate,
    'account_id', pg_temp.acc(p_account), 'purpose', p_purpose, 'source', p_source,
    'in_analytics', p_in_analytics,
    'category_id', (select id from public.categories where name = 'Еда'))))
$$;

create function pg_temp.adjust(p_account text, p_amount bigint, p_mode text, p_date date) returns uuid
language sql as $$
  select pg_temp.entry(jsonb_build_object(
    'type', 'adjustment', 'occurred_on', p_date, 'amount_minor', p_amount, 'account_id', pg_temp.acc(p_account),
    'adjustment_target', 'balance', 'adjustment_sign', -1, 'adjustment_mode', p_mode))
$$;

-- Сценарий: начало учёта 2026-11-01, стартовый долг owe_me 12 000 ₸, i_owe 5 000 ₸.
--   H1 (тенге): всего 150 000 ₸, из них компании 100 000 ₸.
--   KS (тенге): всего 20 000 ₸, компании нет.
--   U1 (доллары): $100 по своему курсу 480 на дату старта; в кэше Нацбанка USD 470,5 (11-02)
--      и 475,25 (11-03): в итог идёт последний курс.
--   E1 (евро): €50 по своему курсу; курса EUR в кэше нет, в итог не входит.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select public.setup_start('2026-11-01', 1200000, 500000);
select public.create_category('Еда');
select public.create_account(p_name => 'H1', p_type => 'card', p_start_date => '2026-11-01',
  p_total_minor => 15000000, p_company_minor => 10000000);
select public.create_account(p_name => 'KS', p_type => 'card', p_start_date => '2026-11-01',
  p_total_minor => 2000000);
select public.create_account(p_name => 'U1', p_type => 'card', p_currency => 'USD', p_start_date => '2026-11-01',
  p_total_minor => 10000, p_rate_source => 'manual', p_rate => 480);
select public.create_account(p_name => 'E1', p_type => 'card', p_currency => 'EUR', p_start_date => '2026-11-01',
  p_total_minor => 5000, p_rate_source => 'manual', p_rate => 520);
select public.create_account(p_name => 'Старая', p_type => 'cash', p_start_date => '2026-11-01');
select public.archive_account(pg_temp.acc('Старая'));
select pg_temp.nbk_rate('USD', '2026-11-02', 470.5);
select pg_temp.nbk_rate('USD', '2026-11-03', 475.25);

-- 1. личная трата H1 своими 5 000 ₸ (11-02)                 → личные +5 000
select set_config('test.food', pg_temp.expense('H1', 'personal', 500000, '2026-11-02', 'own')::text, true);
-- 2. личная трата H1 деньгами компании 3 000 ₸ (11-02)      → личные +3 000, аванс −3 000, i_owe +3 000
select pg_temp.expense('H1', 'personal', 300000, '2026-11-02', 'company');
-- 3. рабочая трата KS 2 000 ₸ (11-02), аванса нет            → owe_me +2 000, не личные
select pg_temp.expense('KS', 'work', 200000, '2026-11-02');
-- 4. личная трата KS 1 000 ₸ вне разрезов трат (11-03)       → не личные
select pg_temp.expense('KS', 'personal', 100000, '2026-11-03', p_in_analytics => false);
-- 5. личная трата U1 $10 по курсу 480 = 4 800 ₸ (11-03)     → личные +4 800 (в тенге)
select pg_temp.expense('U1', 'personal', 1000, '2026-11-03', p_currency => 'USD', p_rate => '480');
-- 6. корректировка KS −700 ₸ «в разрезах трат» (11-04)       → личные +700
select pg_temp.adjust('KS', 70000, 'plug_analytics', '2026-11-04');
-- 7. корректировка H1 −400 ₸ скрытая (11-04)                 → не личные
select pg_temp.adjust('H1', 40000, 'plug_hidden', '2026-11-04');
-- 8. поступление H1 10 000 ₸ (11-04)                         → не траты
select pg_temp.entry(jsonb_build_object('type', 'income', 'occurred_on', '2026-11-04', 'amount_minor', 1000000,
  'account_id', pg_temp.acc('H1'), 'category_id', (select id from public.categories where name = 'Еда')));
-- 9. возврат покупки по трате 1: 1 500 ₸ (11-05)              → личные −1 500 в периоде возврата
select pg_temp.entry(jsonb_build_object('type', 'refund', 'occurred_on', '2026-11-05', 'amount_minor', 150000,
  'parent_entry_id', current_setting('test.food')));
-- 10. черновик быстрого ввода на H1 (там аванс) 2 000 ₸ (11-04) → не учтён, не личные
select public.quick_capture(jsonb_build_object('occurred_on', '2026-11-04', 'amount_minor', 200000,
  'account_id', pg_temp.acc('H1'), 'purpose', 'personal'));

-- Остатки: H1 = 150 000 − 5 000 − 3 000 − 400 + 10 000 + 1 500 = 153 100 ₸, аванс 97 000 ₸;
-- KS = 20 000 − 2 000 − 1 000 − 700 = 16 300 ₸; U1 = $90 × 475,25 = 42 772,50 ₸; E1 €50 без курса.
-- Всего 153 100 + 16 300 + 42 772,50 = 212 172,50 ₸; компании 97 000 ₸; свои 115 172,50 ₸.
-- Долг: owe_me 12 000 + 2 000 = 14 000 ₸, i_owe 5 000 + 3 000 = 8 000 ₸, итог +6 000 ₸.
select is(
  (select jsonb_build_object(
     'total_balance_minor', o -> 'total_balance_minor', 'total_own_minor', o -> 'total_own_minor',
     'total_company_advance_minor', o -> 'total_company_advance_minor')
   from public.overview('2026-11-01', '2026-11-30') o),
  '{"total_balance_minor": 21217250, "total_own_minor": 11517250, "total_company_advance_minor": 9700000}'::jsonb,
  'overview: total money, own money and company advance in tenge over all accounts, '
  'a foreign account at the latest cached National Bank rate');

select is(
  (select jsonb_build_object('company_owes_me_minor', o -> 'company_owes_me_minor',
     'i_owe_company_minor', o -> 'i_owe_company_minor', 'net_minor', o -> 'net_minor')
   from public.overview('2026-11-01', '2026-11-30') o),
  '{"company_owes_me_minor": 1400000, "i_owe_company_minor": 800000, "net_minor": 600000}'::jsonb,
  'overview: both debt sides and the net with the company');

-- Личные траты ноября: 5 000 + 3 000 + 4 800 + 700 − 1 500 = 12 000 ₸.
select is(
  (select o -> 'personal' from public.overview('2026-11-01', '2026-11-30') o),
  '{"from": "2026-11-01", "to": "2026-11-30", "expenses_minor": 1280000, "adjustments_minor": 70000,
    "refunds_minor": 150000, "spent_minor": 1200000}'::jsonb,
  'personal spending: personal expenses in tenge (own or company money) and adjustments in spending '
  'breakdowns, net of purchase refunds; work, out-of-analytics, hidden adjustments and drafts excluded');

-- 11-03..11-04: только трата U1 4 800 ₸ и корректировка 700 ₸ (трата вне разрезов не считается).
select is(
  (select o -> 'personal' ->> 'spent_minor' from public.overview('2026-11-03', '2026-11-04') o),
  '550000', 'personal spending follows the period: entries outside it are not counted');

-- Возврат считается в периоде своей даты: 11-05 и позже личные траты в минусе.
select is(
  (select o -> 'personal' -> 'spent_minor' from public.overview('2026-11-05', null) o),
  '-150000'::jsonb, 'a purchase refund counts in the period of its own date, so a period can be negative');

-- По умолчанию текущий месяц по Алматы.
select is(
  (select o -> 'personal' ->> 'from' from public.overview() o),
  to_char(date_trunc('month', (now() at time zone 'Asia/Almaty'))::date, 'YYYY-MM-DD'),
  'default period starts on the first day of the current month in Almaty');
select is(
  (select o -> 'personal' ->> 'to' from public.overview() o),
  to_char((date_trunc('month', (now() at time zone 'Asia/Almaty')) + interval '1 month - 1 day')::date, 'YYYY-MM-DD'),
  'default period ends on the last day of the current month in Almaty');

select is(pg_temp.error_of($$ select public.overview('2026-11-30', '2026-11-01') $$),
  '{"code": "period_invalid", "detail": {"from": "2026-11-30", "to": "2026-11-01"}}'::jsonb,
  'period start after its end: period_invalid');

-- Строки счетов: архивный не показывается, у валютного остаток в его валюте и в тенге по курсу.
select is(
  (select jsonb_agg(jsonb_build_object('name', a ->> 'name', 'currency', a ->> 'currency',
     'balance_minor', a -> 'balance_minor', 'advance_minor', a -> 'advance_minor', 'own_minor', a -> 'own_minor',
     'balance_kzt_minor', a -> 'balance_kzt_minor', 'rate', a -> 'rate', 'rate_date', a -> 'rate_date')
     order by a ->> 'name')
   from public.overview('2026-11-01', '2026-11-30') o, jsonb_array_elements(o -> 'accounts') a),
  '[{"name": "E1", "currency": "EUR", "balance_minor": 5000, "advance_minor": 0, "own_minor": 5000,
     "balance_kzt_minor": null, "rate": null, "rate_date": null},
    {"name": "H1", "currency": "KZT", "balance_minor": 15310000, "advance_minor": 9700000, "own_minor": 5610000,
     "balance_kzt_minor": 15310000, "rate": null, "rate_date": null},
    {"name": "KS", "currency": "KZT", "balance_minor": 1630000, "advance_minor": 0, "own_minor": 1630000,
     "balance_kzt_minor": 1630000, "rate": null, "rate_date": null},
    {"name": "U1", "currency": "USD", "balance_minor": 9000, "advance_minor": 0, "own_minor": 9000,
     "balance_kzt_minor": 4277250, "rate": "475.25", "rate_date": "2026-11-03"}]'::jsonb,
  'account rows: balance, advance and own per active account, a foreign one also in tenge at the rate used');

select is((select o -> 'unconverted' from public.overview() o),
  jsonb_build_array(jsonb_build_object('account_id', pg_temp.acc('E1'), 'name', 'E1', 'currency', 'EUR',
    'balance_minor', 5000)),
  'a foreign account without a cached rate is listed as not counted in the tenge totals');

select is((select o -> 'inbox_items' from public.overview() o), '1'::jsonb,
  'overview tells how many items wait in the inbox');

-- Выборка v_overview (док 05): те же агрегаты за текущий месяц.
select is(
  (select jsonb_build_object('b', total_balance_minor, 'o', total_own_minor, 'c', total_company_advance_minor,
     'n', net_minor) from public.v_overview),
  '{"b": 21217250, "o": 11517250, "c": 9700000, "n": 600000}'::jsonb,
  'v_overview gives the same totals for the current month');

-- Другой пользователь видит только своё; не разрешённый получает not_allowed.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000b');
select is(
  (select jsonb_build_object('b', o -> 'total_balance_minor', 's', o -> 'personal' -> 'spent_minor',
     'a', o -> 'accounts') from public.overview('2026-11-01', '2026-11-30') o),
  '{"b": 0, "s": 0, "a": []}'::jsonb,
  'another user sees only their own overview');
select pg_temp.login_as('00000000-0000-0000-0000-00000000000c');
select is(pg_temp.error_of($$ select public.overview() $$) ->> 'code', 'not_allowed',
  'a user not on the allowlist gets not_allowed');

select * from finish();
rollback;
