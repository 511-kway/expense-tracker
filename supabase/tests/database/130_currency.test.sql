-- Валюта (док 03, раздел 5; док 06, раздел 10; spec.md, истории 60–63): тенговый эквивалент тремя
-- способами (курс Нацбанка из кэша fx_rates, свой курс, сумма в тенге), округление до тиына один раз
-- при сохранении; остаток в валюте счёта, аванс и долг в тенге; валютный счёт без аванса.
-- Суммы в минимальных единицах: $100 = 10 000 центов, 48 000 ₸ = 4 800 000 тиынов.
begin;
create extension if not exists pgtap with schema extensions;
select plan(44);

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

-- Курс Нацбанка в кэше (его кладёт Edge Function fetch_rates от service_role).
create function pg_temp.nbk_rate(p_currency text, p_date date, p_rate numeric) returns void
language plpgsql as $$
declare v_role text := current_setting('role');
begin
  perform set_config('role', 'postgres', true);
  insert into public.fx_rates (rate_date, currency, rate) values (p_date, p_currency, p_rate);
  perform set_config('role', v_role, true);
end $$;

create function pg_temp.account(p_name text, p_total bigint default 0, p_company bigint default 0,
                                p_currency text default 'KZT') returns uuid language sql as $$
  select (public.create_account(p_name => p_name, p_type => 'card', p_start_date => '2026-11-01',
            p_total_minor => p_total, p_company_minor => p_company, p_currency => p_currency) ->> 'account_id')::uuid
$$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

-- Трата с валютой и способом пересчёта (пустые поля не отправляются).
create function pg_temp.expense(p_account text, p_purpose text, p_amount bigint, p_currency text,
                                p_rate_source text default null, p_rate jsonb default null,
                                p_kzt bigint default null, p_date date default '2026-11-02') returns jsonb
language sql as $$
  select public.create_entry(jsonb_strip_nulls(jsonb_build_object(
    'type', 'expense', 'occurred_on', p_date, 'amount_minor', p_amount, 'currency', p_currency,
    'rate_source', p_rate_source, 'rate', p_rate, 'amount_kzt_minor', p_kzt,
    'account_id', pg_temp.acc(p_account), 'purpose', p_purpose,
    'category_id', (select id from public.categories where name = 'Реклама'))))
$$;

create function pg_temp.state(p_account text)
returns table (bal bigint, adv bigint, owe_me bigint, i_owe bigint) language sql as $$
  select b.balance_minor, b.advance_minor, s.company_owes_me_minor, s.i_owe_company_minor
  from public.v_account_balances b, public.v_company_settlement s where b.name = p_account
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

-- TC-FX-NBK: курс USD на дату = 480; expense work H1 $100, rate_source=nbk. H1 с авансом 30 000 ₸.
select pg_temp.scenario(1);
select pg_temp.account('H1', 10000000, 3000000);
select pg_temp.nbk_rate('USD', '2026-11-02', 480);
select pg_temp.expense('H1', 'work', 10000, 'USD', 'nbk');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (5200000::bigint, 0::bigint, 1800000::bigint, 0::bigint) $$,
  'TC-FX-NBK: a dollar expense from a tenge card takes 48 000 ₸ from the balance, the advance and the debt');
select results_eq($$ select amount_minor, currency, amount_kzt_minor, rate, rate_source::text from public.v_entries
                     where type = 'expense' $$,
  $$ values (10000::bigint, 'USD'::text, 4800000::bigint, 480::numeric, 'nbk'::text) $$,
  'TC-FX-NBK: the entry keeps $100, its 48 000 ₸ equivalent and the rate of the National Bank');

-- TC-FX-MANUAL: свой курс 480 строкой (без float), тот же результат.
select pg_temp.scenario(2);
select pg_temp.account('H1', 10000000, 3000000);
select pg_temp.expense('H1', 'work', 10000, 'USD', 'manual', '"480"');
select results_eq($$ select s.*, e.amount_kzt_minor, e.rate from pg_temp.state('H1') s, public.v_entries e
                     where e.type = 'expense' $$,
  $$ values (5200000::bigint, 0::bigint, 1800000::bigint, 0::bigint, 4800000::bigint, 480::numeric) $$,
  'TC-FX-MANUAL: an own rate gives the same 48 000 ₸ equivalent, the engine counts in tenge');

-- TC-FX-DERIVED: сумма в тенге 48 000, курс выводится справочно.
select pg_temp.scenario(3);
select pg_temp.account('H1', 10000000, 3000000);
select pg_temp.expense('H1', 'work', 10000, 'USD', 'derived', p_kzt => 4800000);
select results_eq($$ select s.*, e.amount_kzt_minor, e.rate from pg_temp.state('H1') s, public.v_entries e
                     where e.type = 'expense' $$,
  $$ values (5200000::bigint, 0::bigint, 1800000::bigint, 0::bigint, 4800000::bigint, 480::numeric) $$,
  'TC-FX-DERIVED: the tenge amount is the equivalent, the rate is derived for reference');

-- Округление один раз до тиына: $12,34 × 453,64567891 = 559 798,767… тиына → 559 799.
select pg_temp.scenario(4);
select pg_temp.account('H1', 10000000);
select pg_temp.expense('H1', 'personal', 1234, 'USD', 'manual', '"453.645678912"');
select results_eq($$ select e.amount_kzt_minor, e.rate, s.bal from public.v_entries e, pg_temp.state('H1') s
                     where e.amount_minor = 1234 $$,
  $$ values (559799::bigint, 453.64567891::numeric, 9440201::bigint) $$,
  'the equivalent is rounded to a whole tiyn once, the rate keeps 8 decimals');
select pg_temp.expense('H1', 'personal', 1, 'USD', 'derived', p_kzt => 1);
select results_eq($$ select amount_kzt_minor, rate from public.v_entries where amount_minor = 1 $$,
  $$ values (1::bigint, 1::numeric) $$, 'a derived rate is the tenge amount over the amount');

-- Эквивалент сохраняется один раз: новый курс в кэше и пересчёт журнала его не меняют.
reset role;
update public.fx_rates set rate = 500 where currency = 'USD' and rate_date = '2026-11-02';
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000000001',
  'role', 'authenticated')::text, true);
select pg_temp.expense('H1', 'personal', 100000, 'KZT');
select results_eq($$ select bal, owe_me from pg_temp.state('H1') $$, $$ values (5100000::bigint, 1800000::bigint) $$,
  'a saved equivalent stays: a later rate in the cache and a full replay do not change it');

-- Тенговый эквивалент для блока пересчёта в форме считает сервер тем же правилом.
select is(public.convert_amount('USD', 1234, '2026-11-02', 'manual', '453.645678912'),
  '{"amount_kzt_minor": 559799, "rate": 453.64567891, "rate_source": "manual"}'::jsonb,
  'the conversion block gets the equivalent from the server');
select is(public.convert_amount('USD', 10000, '2026-11-02', 'nbk'),
  '{"amount_kzt_minor": 5000000, "rate": 500, "rate_source": "nbk"}'::jsonb,
  'the conversion block: the National Bank rate on the date from the cache');
select is(public.convert_amount('KZT', 10000, '2026-11-02', 'manual', '2'),
  '{"amount_kzt_minor": 10000, "rate": null, "rate_source": null}'::jsonb,
  'the conversion block: tenge is its own equivalent');
select is(pg_temp.error_of($$ select public.convert_amount('USD', 10000, '2026-11-09', 'nbk') $$) ->> 'code',
  'fx_rate_missing', 'the conversion block: no cached rate for the date');

-- Ввод пересчёта.
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1000, 'USD', 'nbk', p_date => '2026-11-03') $$),
  '{"code": "fx_rate_missing", "detail": {"currency": "USD", "rate_date": "2026-11-03"}}'::jsonb,
  'no National Bank rate in the cache for the date: fx_rate_missing (the form fetches it or offers manual input)');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1000, 'USD') $$),
  '{"code": "missing_required", "detail": {"field": "rate_source"}}'::jsonb,
  'an amount in another currency needs a way to get the tenge equivalent');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1000, 'USD', 'manual') $$),
  '{"code": "missing_required", "detail": {"field": "rate"}}'::jsonb, 'an own rate needs the rate');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1000, 'USD', 'manual', '"4,8"') $$),
  '{"code": "field_invalid", "detail": {"field": "rate"}}'::jsonb, 'a rate is a decimal with a dot');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1000, 'USD', 'manual', '0') $$),
  '{"code": "field_invalid", "detail": {"field": "rate"}}'::jsonb, 'a rate must be above zero');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1000, 'USD', 'derived') $$),
  '{"code": "missing_required", "detail": {"field": "amount_kzt_minor"}}'::jsonb,
  'a tenge amount method needs the tenge amount');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1, 'USD', 'manual', '"0.4"') $$),
  '{"code": "amount_not_positive", "detail": {"field": "amount_kzt_minor"}}'::jsonb,
  'an equivalent rounded to zero tiyn is rejected');
select is(pg_temp.error_of($$ select pg_temp.expense('H1', 'personal', 1000, 'US') $$),
  '{"code": "currency_invalid", "detail": {"currency": "US"}}'::jsonb, 'currency is an ISO code');
select pg_temp.expense('H1', 'personal', 50000, 'KZT', 'manual', '"480"', 1);
select results_eq($$ select amount_kzt_minor, rate, rate_source::text from public.v_entries where amount_minor = 50000 $$,
  $$ values (50000::bigint, null::numeric, null::text) $$,
  'a tenge amount is its own equivalent: a sent rate is dropped');

-- Валютный счёт (история 63): карта в лирах, стартовый остаток 1 000 ₺ по курсу Нацбанка 9,08.
select pg_temp.scenario(5);
select pg_temp.account('H1', 10000000, 5000000);
select pg_temp.nbk_rate('TRY', '2026-11-01', 9.08);
select pg_temp.nbk_rate('TRY', '2026-11-02', 9.10);
select public.create_account(p_name => 'Лиры', p_type => 'card', p_currency => 'TRY', p_start_date => '2026-11-01',
  p_total_minor => 100000, p_rate_source => 'nbk');
select results_eq($$ select * from pg_temp.state('Лиры') $$,
  $$ values (100000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'a lira account: the opening balance is in liras, no advance');
select results_eq($$ select amount_minor, currency, amount_kzt_minor, rate from public.v_entries
                     where account_name = 'Лиры' and title = 'Стартовый остаток' $$,
  $$ values (100000::bigint, 'TRY'::text, 908000::bigint, 9.08::numeric) $$,
  'the opening balance of a lira account carries its tenge equivalent');
select is(pg_temp.error_of($$ select public.create_account(p_name => 'Лиры 2', p_type => 'card', p_currency => 'TRY',
    p_start_date => '2026-11-01', p_total_minor => 100000, p_company_minor => 1, p_rate_source => 'nbk') $$),
  '{"code": "foreign_advance_not_supported", "detail": {"account_currency": "TRY"}}'::jsonb,
  'a non-tenge account holds no company advance: «из них компании» must be zero');
select is(pg_temp.error_of($$ select public.preview_account_opening(100000, 1, 'TRY') $$) ->> 'code',
  'foreign_advance_not_supported', 'the opening preview rejects company money on a non-tenge account too');
select is(pg_temp.error_of($$ select public.create_account(p_name => 'Лиры 2', p_type => 'card', p_currency => 'TRY',
    p_start_date => '2026-11-01', p_total_minor => 100000) $$),
  '{"code": "missing_required", "detail": {"field": "rate_source"}}'::jsonb,
  'the opening balance of a non-tenge account needs a way to get its tenge equivalent');

-- Трата в лирах с лировой карты: остаток в лирах, долг в тенге. 500 ₺ × 9,10 = 4 550 ₸.
select pg_temp.expense('Лиры', 'work', 50000, 'TRY', 'nbk');
select results_eq($$ select * from pg_temp.state('Лиры') $$,
  $$ values (50000::bigint, 0::bigint, 455000::bigint, 0::bigint) $$,
  'a lira expense from a lira card: the balance drops in liras, «компания должна мне» grows in tenge');
select pg_temp.expense('Лиры', 'personal', 10000, null, 'manual', '"9"');
select results_eq($$ select currency, amount_kzt_minor, source::text from public.v_entries where amount_minor = 10000 $$,
  $$ values ('TRY'::text, 90000::bigint, 'own'::text) $$,
  'the currency defaults to the account currency; with no advance a personal expense is own money');
select is(pg_temp.error_of($$ select pg_temp.expense('Лиры', 'personal', 1000, 'USD', 'nbk') $$),
  '{"code": "account_currency_mismatch", "detail": {"currency": "USD", "account_currency": "TRY"}}'::jsonb,
  'a non-tenge account with an entry in a third currency is out of scope');
select is(pg_temp.error_of($$ select pg_temp.expense('Лиры', 'personal', 1000, 'KZT') $$) ->> 'code',
  'account_currency_mismatch', 'a lira account takes no tenge entries');

-- Аванс только на тенговых счетах, долг и деньги компании только в тенге.
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'company_topup',
    'occurred_on', '2026-11-02', 'amount_minor', 1000, 'account_id', %L)) $$, pg_temp.acc('Лиры'))),
  jsonb_build_object('code', 'foreign_advance_not_supported', 'detail', jsonb_build_object(
    'account_id', pg_temp.acc('Лиры'), 'account_currency', 'TRY')),
  'a company top-up goes to tenge accounts only');
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'company_topup',
    'occurred_on', '2026-11-02', 'amount_minor', 1000, 'currency', 'USD', 'rate_source', 'nbk', 'account_id', %L)) $$,
    pg_temp.acc('H1'))) ->> 'code',
  'foreign_amount_not_supported', 'a company top-up is in tenge only');
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'settlement',
    'occurred_on', '2026-11-02', 'amount_minor', 1000, 'currency', 'USD', 'rate_source', 'nbk', 'account_id', %L,
    'settlement_direction', 'i_paid_company')) $$, pg_temp.acc('H1'))) ->> 'code',
  'foreign_amount_not_supported', 'a debt settlement is in tenge only');
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'adjustment',
    'occurred_on', '2026-11-02', 'amount_minor', 1000, 'account_id', %L, 'adjustment_sign', 1,
    'adjustment_mode', 'plug_hidden', 'adjustment_affects_advance', true, 'rate_source', 'nbk')) $$,
    pg_temp.acc('Лиры'))) ->> 'code',
  'foreign_advance_not_supported', 'a balance adjustment of a lira account cannot touch the advance');
select public.create_entry(jsonb_build_object('type', 'adjustment', 'occurred_on', '2026-11-02',
  'amount_minor', 2000, 'account_id', pg_temp.acc('Лиры'), 'adjustment_sign', -1, 'adjustment_mode', 'plug_hidden',
  'rate_source', 'derived', 'amount_kzt_minor', 18000));
select results_eq($$ select bal, adv from pg_temp.state('Лиры') $$, $$ values (38000::bigint, 0::bigint) $$,
  'a balance adjustment of a lira account moves the balance in liras');

-- Переводы между лировыми счетами: только «перевод своих», в лирах.
select public.create_account(p_name => 'Лиры наличные', p_type => 'cash', p_currency => 'TRY',
  p_start_date => '2026-11-01');
select public.create_entry(jsonb_build_object('type', 'transfer', 'occurred_on', '2026-11-02',
  'amount_minor', 10000, 'account_id', pg_temp.acc('Лиры'), 'to_account_id', pg_temp.acc('Лиры наличные'),
  'transfer_purpose', 'move_own', 'fee_minor', 100, 'fee_payer', 'own', 'rate_source', 'nbk'));
select results_eq($$ select (select bal from pg_temp.state('Лиры')), (select bal from pg_temp.state('Лиры наличные')) $$,
  $$ values (27900::bigint, 10000::bigint) $$, 'a lira transfer with a fee moves liras between lira accounts');
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'transfer',
    'occurred_on', '2026-11-02', 'amount_minor', 1000, 'account_id', %L, 'to_account_id', %L,
    'transfer_purpose', 'move_company', 'rate_source', 'nbk')) $$, pg_temp.acc('Лиры'), pg_temp.acc('Лиры наличные'))),
  jsonb_build_object('code', 'foreign_advance_not_supported', 'detail', jsonb_build_object(
    'account_id', pg_temp.acc('Лиры'), 'account_currency', 'TRY')),
  'a non-tenge transfer is «перевод своих» only: no advance on non-tenge accounts');
select public.create_account(p_name => 'H2', p_type => 'card', p_start_date => '2026-11-01');
select is(pg_temp.error_of(format($$ select public.create_entry(jsonb_build_object('type', 'transfer',
    'occurred_on', '2026-11-02', 'amount_minor', 1000, 'currency', 'USD', 'rate_source', 'nbk', 'account_id', %L,
    'to_account_id', %L, 'transfer_purpose', 'move_own')) $$, pg_temp.acc('H1'), pg_temp.acc('H2'))) ->> 'code',
  'cross_currency_transfer', 'a transfer is in the currency of its accounts');

-- Возврат покупки по валютной трате (док 03, 4.8: откатываем тенговый эквивалент траты по её курсу):
-- $1 по курсу 480,015 = 48 002 тиына (480,015 округляется вверх); три возврата 33, 33 и 34 цента.
-- Каждый эквивалент по накопленной сумме: 15 841, 15 840, 16 321, без потери тиына.
select pg_temp.scenario(6);
select pg_temp.account('H1', 10000000);
select set_config('test.parent', pg_temp.expense('H1', 'work', 100, 'USD', 'manual', '"480.015"') ->> 'entry_id', true);
create function pg_temp.refund(p_amount bigint) returns jsonb language sql as $$
  select public.create_entry(jsonb_build_object('type', 'refund', 'occurred_on', '2026-11-03',
    'amount_minor', p_amount, 'parent_entry_id', current_setting('test.parent')))
$$;
select pg_temp.refund(33);
select is(public.refund_remaining(current_setting('test.parent')::uuid),
  '{"currency": "USD", "parent_amount_minor": 100, "refunded_minor": 33, "remaining_minor": 67}'::jsonb,
  'the refund form gets what is left of a dollar expense in dollars');
select pg_temp.refund(33);
select pg_temp.refund(34);
select results_eq($$ select currency, amount_kzt_minor, rate, rate_source::text from public.v_entries
                     where type = 'refund' order by seq $$,
  $$ values ('USD'::text, 15841::bigint, 480.015::numeric, 'manual'::text), ('USD', 15840, 480.015, 'manual'),
            ('USD', 16321, 480.015, 'manual') $$,
  'refunds of a dollar expense: its currency and rate, equivalents by the running total');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 0::bigint, 0::bigint, 0::bigint) $$,
  'after a full refund of a dollar expense the balance and the debt are back exactly');
select is(pg_temp.error_of($$ select pg_temp.refund(1) $$) ->> 'code', 'refund_too_big',
  'a dollar refund above what is left is rejected');

-- Кэш курсов: читают разрешённые пользователи, пишет только service_role.
select is((select rate from public.fx_rates where currency = 'USD'), 500::numeric,
  'an allowed user reads the rate cache');
select throws_ok($$ insert into public.fx_rates (rate_date, currency, rate) values ('2026-11-05', 'EUR', 500) $$,
  '42501', null, 'a client cannot write the rate cache');
reset role;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000cc', 'stranger@example.com');
insert into public.app_users (email, user_id, allowed) values ('stranger@example.com', '00000000-0000-0000-0000-0000000000cc', false);
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000cc', 'role', 'authenticated')::text, true);
select is((select count(*) from public.fx_rates), 0::bigint, 'a user on the waitlist does not read the rate cache');
reset role;

select * from finish();
rollback;
