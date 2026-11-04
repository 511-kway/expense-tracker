-- Быстрый ввод и инбокс (ADR-0009; док 06 TC-QUICK-CAPTURE; spec.md, истории 69–75):
-- quick_capture сохраняет трату учтённой, если движку хватает данных, иначе черновиком
-- «источник?», который на счётчики не влияет; promote_draft дозаполняет черновик и пересчитывает;
-- v_inbox и v_inbox_count отдают черновики и учтённые траты без категории.
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(31);

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

create function pg_temp.account(p_name text, p_total bigint default 0, p_company bigint default 0,
                                p_start date default '2026-11-01') returns uuid language sql as $$
  select (public.create_account(p_name => p_name, p_type => 'card', p_start_date => p_start,
            p_total_minor => p_total, p_company_minor => p_company) ->> 'account_id')::uuid
$$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

create function pg_temp.category() returns uuid language sql as $$
  select id from public.categories where name = 'Реклама'
$$;

-- Быстрый ввод: сумма, счёт, личное/работа, короткий текст.
create function pg_temp.quick(p_account text, p_purpose text, p_amount bigint, p_title text default null,
                              p_date date default '2026-11-02') returns jsonb language sql as $$
  select public.quick_capture(jsonb_strip_nulls(jsonb_build_object(
    'occurred_on', p_date, 'amount_minor', p_amount, 'account_id', pg_temp.acc(p_account),
    'purpose', p_purpose, 'title', p_title)))
$$;

-- Остаток и аванс счёта, обе стороны долга.
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

-- TC-QUICK-CAPTURE: H1 всего 100 000 ₸, из них компании 50 000; KS всего 10 000, компании 0.
select pg_temp.scenario(1);
select pg_temp.account('H1', 10000000, 5000000);
select pg_temp.account('KS', 1000000, 0);

select is(pg_temp.quick('H1', 'work', 100000, 'Реклама в ленте') ->> 'status', 'done',
  'quick capture: work expense on any account is done');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9900000::bigint, 4900000::bigint, 0::bigint, 0::bigint) $$,
  'done quick work expense is counted: spends the advance first');

select set_config('test.r', pg_temp.quick('KS', 'personal', 50000, 'Кофе')::text, true);
select results_eq(
  $$ select current_setting('test.r')::jsonb ->> 'status', e.source::text, e.category_id
     from public.entries e where e.id = (current_setting('test.r')::jsonb ->> 'entry_id')::uuid $$,
  $$ values ('done'::text, 'own'::text, null::uuid) $$,
  'quick personal expense on an account without advance: done, source own, no category');
select results_eq($$ select bal, adv from pg_temp.state('KS') $$,
  $$ values (950000::bigint, 0::bigint) $$,
  'done quick personal expense is counted');
select results_eq(
  $$ select kind, title, amount_minor, account_name, source_pending from public.v_inbox order by title $$,
  $$ values ('no_category'::text, 'Кофе'::text, 50000::bigint, 'KS'::text, false),
            ('no_category', 'Реклама в ленте', 100000, 'H1', false) $$,
  'done expenses without category wait in the inbox as «без категории»');

-- Личное с H1, где есть аванс: чьими деньгами, непонятно, поэтому черновик «источник?».
select set_config('test.draft', pg_temp.quick('H1', 'personal', 70000, 'Такси')::text, true);
select results_eq(
  $$ select current_setting('test.draft')::jsonb ->> 'status',
            (current_setting('test.draft')::jsonb ->> 'source_pending')::boolean, e.source::text
     from public.entries e where e.id = (current_setting('test.draft')::jsonb ->> 'entry_id')::uuid $$,
  $$ values ('draft'::text, true, null::text) $$,
  'quick personal expense on an account with advance: draft, source_pending, no source');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9900000::bigint, 4900000::bigint, 0::bigint, 0::bigint) $$,
  'draft does not change the counters');
select public.recompute();
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9900000::bigint, 4900000::bigint, 0::bigint, 0::bigint) $$,
  'draft stays out of a full recompute');
select results_eq(
  $$ select kind, title, source_pending from public.v_inbox
     order by kind = 'draft' desc, title $$,
  $$ values ('draft'::text, 'Такси'::text, true),
            ('no_category', 'Кофе', false), ('no_category', 'Реклама в ленте', false) $$,
  'inbox: the draft with «источник?» and the expenses without category');
select is((select items from public.v_inbox_count), 3, 'inbox badge counts on the server');

-- Источник указан сразу: считать можно, учтена.
select results_eq(
  $$ select public.quick_capture(jsonb_build_object('occurred_on', '2026-11-02', 'amount_minor', 10000,
       'account_id', pg_temp.acc('H1'), 'purpose', 'personal', 'source', 'company', 'title', 'Обед')) ->> 'status' $$,
  $$ values ('done'::text) $$,
  'quick personal expense with a given source is done');
-- Полная форма по-прежнему требует категорию; черновик создаёт только быстрый ввод.
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'expense',
    'occurred_on', '2026-11-02', 'amount_minor', 100, 'account_id', pg_temp.acc('KS'), 'purpose', 'work')) $$),
  '{"code": "missing_required", "detail": {"field": "category_id"}}'::jsonb,
  'full form: expense still requires a category');
select is(pg_temp.error_of($$ select public.create_entry(jsonb_build_object('type', 'expense', 'status', 'draft',
    'occurred_on', '2026-11-02', 'amount_minor', 100, 'account_id', pg_temp.acc('KS'), 'purpose', 'work',
    'category_id', pg_temp.category())) $$) ->> 'code',
  'entry_status_not_supported', 'full form cannot create a draft');
-- Быстрый ввод проверяет всё, кроме источника, как у учтённой траты.
select is(pg_temp.error_of($$ select pg_temp.quick('H1', 'personal', 0) $$) ->> 'code',
  'amount_not_positive', 'quick capture: amount must be positive, draft or not');
select is(pg_temp.error_of($$ select pg_temp.quick('H1', 'personal', 100, null, '2026-10-31') $$) ->> 'code',
  'entry_before_start', 'quick capture: no draft before the accounting start');
select is(pg_temp.error_of($$ select public.quick_capture(jsonb_build_object('amount_minor', 100,
    'account_id', pg_temp.acc('H1'))) $$),
  '{"code": "missing_required", "detail": {"field": "purpose"}}'::jsonb,
  'quick capture: personal or work is required');
select set_config('test.today', public.quick_capture(jsonb_build_object('amount_minor', 100,
  'account_id', pg_temp.acc('KS'), 'purpose', 'work', 'title', 'Сегодня'))::text, true);
select is((select occurred_on from public.entries
           where id = (current_setting('test.today')::jsonb ->> 'entry_id')::uuid),
  (now() at time zone 'Asia/Almaty')::date, 'quick capture date defaults to today in Almaty');

-- Дозаполнение черновика «Такси» (личное с H1 на 700 ₸). Состояние H1 до: остаток 98 900 ₸,
-- аванс 48 900, компания должна мне 1 (работа «Сегодня» с KS), я должен компании 100 (обед
-- деньгами компании).
create function pg_temp.taxi(p_source text) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('type', 'expense', 'occurred_on', '2026-11-02',
    'amount_minor', 70000, 'account_id', pg_temp.acc('H1'), 'purpose', 'personal', 'source', p_source,
    'title', 'Такси'))
$$;
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9890000::bigint, 4890000::bigint, 100::bigint, 10000::bigint) $$,
  'before promote: the draft is still out of the counters');
select is(pg_temp.error_of($$ select public.promote_draft(
    (current_setting('test.draft')::jsonb ->> 'entry_id')::uuid, pg_temp.taxi(null)) $$) ->> 'code',
  'source_required', 'promote: an account with advance still needs the source');
select results_eq(
  $$ select r -> 'deltas' -> 'accounts' -> (pg_temp.acc('H1')::text) ->> 'balance_minor',
            r -> 'deltas' -> 'accounts' -> (pg_temp.acc('H1')::text) ->> 'advance_minor',
            r -> 'deltas' ->> 'i_owe_company_minor', r ->> 'status'
     from (select public.preview_entry(pg_temp.taxi('company'),
             (current_setting('test.draft')::jsonb ->> 'entry_id')::uuid) as r) q $$,
  $$ values ('-70000'::text, '-70000'::text, '70000'::text, 'done'::text) $$,
  'preview of a promote shows the effect the draft will have');
select is((select status::text from public.entries
           where id = (current_setting('test.draft')::jsonb ->> 'entry_id')::uuid),
  'draft', 'preview of a promote saves nothing');
select results_eq(
  $$ select public.promote_draft((current_setting('test.draft')::jsonb ->> 'entry_id')::uuid,
       pg_temp.taxi('company')) ->> 'status' $$,
  $$ values ('done'::text) $$,
  'promote_draft makes the draft done');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9820000::bigint, 4820000::bigint, 100::bigint, 80000::bigint) $$,
  'promote recomputes: company money spends the advance and I owe the company');
select results_eq(
  $$ select kind, source_pending from public.v_inbox where title = 'Такси' $$,
  $$ values ('no_category'::text, false) $$,
  'promoted draft without category stays in the inbox as «без категории»');
select is(pg_temp.error_of($$ select public.promote_draft(
    (current_setting('test.draft')::jsonb ->> 'entry_id')::uuid, pg_temp.taxi('company')) $$) ->> 'code',
  'entry_not_draft', 'promote: only a draft can be promoted');

-- Категорию проставили правкой: трата уходит из инбокса.
select public.update_entry((current_setting('test.r')::jsonb ->> 'entry_id')::uuid, jsonb_build_object(
  'type', 'expense', 'occurred_on', '2026-11-02', 'amount_minor', 50000, 'account_id', pg_temp.acc('KS'),
  'purpose', 'personal', 'title', 'Кофе', 'category_id', pg_temp.category()));
select is((select count(*)::int from public.v_inbox where title = 'Кофе'), 0,
  'an expense with a category leaves the inbox');

-- Черновик можно удалить; чужой инбокс не виден.
select set_config('test.draft2', pg_temp.quick('H1', 'personal', 1000, 'Мелочь')::text, true);
select public.delete_entry((current_setting('test.draft2')::jsonb ->> 'entry_id')::uuid);
select is((select count(*)::int from public.v_inbox where title = 'Мелочь'), 0, 'a draft can be deleted');
select pg_temp.scenario(2);
select is((select items from public.v_inbox_count), 0, 'another user sees an empty inbox');
select is(pg_temp.error_of($$ select public.promote_draft(
    (current_setting('test.draft')::jsonb ->> 'entry_id')::uuid, pg_temp.taxi('own')) $$) ->> 'code',
  'entry_not_found', 'promote: someone else''s draft is not found');

-- Без отметки «разрешён» быстрого ввода и дозаполнения нет.
select set_config('role', 'postgres', true);
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000cc', 'stranger@example.com');
insert into public.app_users (email, user_id, allowed) values ('stranger@example.com', '00000000-0000-0000-0000-0000000000cc', false);
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000cc', 'role', 'authenticated')::text, true);
select throws_ok($$ select public.quick_capture('{}') $$, '42501', 'not_allowed', 'not allowed: quick_capture');
select throws_ok($$ select public.promote_draft(gen_random_uuid(), '{}') $$, '42501', 'not_allowed', 'not allowed: promote_draft');

select * from finish();
rollback;
