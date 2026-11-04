-- Категории трат (док 02 раздел 3, док 04 раздел 3): создать, переименовать, архивировать,
-- название уникально у пользователя без учёта регистра.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

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

create function pg_temp.category_id(p_name text) returns uuid language sql as $$
  select id from public.categories where name = p_name
$$;

select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');

select is((public.create_category(' Реклама ') ->> 'category_id')::uuid, pg_temp.category_id('Реклама'),
  'create category: id in the answer, name trimmed');
select public.create_category('Аптека');
select results_eq($$ select name, is_archived from public.categories order by name $$,
  $$ values ('Аптека'::text, false), ('Реклама', false) $$, 'categories list');

select is(pg_temp.error_of($$ select public.create_category('реклама') $$),
  '{"code": "category_name_taken", "detail": {"name": "реклама"}}'::jsonb,
  'the same category twice is rejected, case does not matter');
select is(pg_temp.error_of($$ select public.create_category('  ') $$),
  '{"code": "missing_required", "detail": {"field": "name"}}'::jsonb, 'category name is required');

select public.rename_category(pg_temp.category_id('Аптека'), 'Лекарства');
select results_eq($$ select name from public.categories order by name $$,
  $$ values ('Лекарства'::text), ('Реклама') $$, 'rename category');
select is(pg_temp.error_of(format($$ select public.rename_category(%L, 'РЕКЛАМА') $$,
    pg_temp.category_id('Лекарства'))) ->> 'code',
  'category_name_taken', 'rename to a taken name is rejected');
select public.rename_category(pg_temp.category_id('Лекарства'), 'лекарства');
select is((select name from public.categories where name ilike 'лекарства'), 'лекарства',
  'rename may change only the case of its own name');

select public.archive_category(pg_temp.category_id('Реклама'));
select is((select is_archived from public.categories where name = 'Реклама'), true, 'archive category');
select public.unarchive_category(pg_temp.category_id('Реклама'));
select is((select is_archived from public.categories where name = 'Реклама'), false, 'unarchive category');

select throws_ok($$ insert into public.categories (name) values ('Прямо') $$, '42501', null,
  'client cannot insert categories directly');
reset role;

select set_config('test.ads', pg_temp.category_id('Реклама')::text, true);
select pg_temp.login_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*) from public.categories), 0::bigint, 'other user sees no categories');
select is(pg_temp.error_of(format($$ select public.rename_category(%L, 'Чужая') $$,
    current_setting('test.ads'))) ->> 'code',
  'category_not_found', 'other user cannot rename someone else''s category');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-00000000000c');
select throws_ok($$ select public.create_category('Продукты') $$, '42501', 'not_allowed',
  'not allowed: create_category raises not_allowed');
reset role;

select * from finish();
rollback;
