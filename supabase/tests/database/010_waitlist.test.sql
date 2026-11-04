-- TC-WAITLIST (док 06, раздел 12; ADR-0007): вход, лист ожидания, разрешённый владелец.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

-- Пользователи GoTrue: владелец и посторонний.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com', '{"full_name":"Owner"}'),
  ('00000000-0000-0000-0000-00000000000b', 'Stranger@Example.com', '{"full_name":"Stranger"}');

-- Сессия как у GoTrue: роль authenticated и JWT с email и профилем Google.
create function pg_temp.login_as(uid uuid, email text) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', uid, 'email', email, 'role', 'authenticated',
             'user_metadata', (select raw_user_meta_data from auth.users where id = uid))::text, true);
$$;

select pg_temp.login_as('00000000-0000-0000-0000-00000000000b', 'Stranger@Example.com');
select is((public.register_login() ->> 'allowed')::boolean, false,
  'stranger: register_login returns allowed = false');

select (public.register_login() ->> 'allowed')::boolean;  -- вторая попытка
reset role;

-- Лист ожидания владелец смотрит в Studio: строка с lower-case email, именем и счётчиком.
select results_eq(
  $$ select email, name, allowed, attempts from public.app_users
     where user_id = '00000000-0000-0000-0000-00000000000b' $$,
  $$ values ('stranger@example.com'::text, 'Stranger'::text, false, 2) $$,
  'stranger is on the waitlist, attempts grow');
select ok(
  (select first_seen_at <= last_attempt_at from public.app_users where email = 'stranger@example.com'),
  'first and last attempt are recorded');

-- Клиент не видит лист ожидания напрямую.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000b', 'Stranger@Example.com');
select throws_ok($$ select * from public.app_users $$, '42501', null,
  'app_users is not readable from the client');
select is(public.is_allowed(), false, 'is_allowed() = false before the flag');
select throws_ok($$ select public.assert_allowed() $$, '42501', 'not_allowed',
  'not allowed: RPC guard raises not_allowed');

-- Владелец: строку заранее создаёт allow_owner(ADMIN_EMAIL) (сброс базы, деплой), до первого входа.
select throws_ok($$ select public.allow_owner('owner@example.com') $$, '42501', null,
  'client cannot call allow_owner');
reset role;
set local role service_role;
select lives_ok($$ select public.allow_owner('Owner@Example.com') $$, 'service_role allows the owner');
select lives_ok($$ select public.allow_owner('owner@example.com') $$, 'allow_owner is idempotent');
reset role;

select pg_temp.login_as('00000000-0000-0000-0000-00000000000a', 'owner@example.com');
select is((public.register_login() ->> 'allowed')::boolean, true, 'owner: register_login returns allowed = true');
select is(public.is_allowed(), true, 'owner: is_allowed() = true');
select lives_ok($$ select public.assert_allowed() $$, 'owner: RPC guard passes');
reset role;

-- Тот же посторонний после ручной отметки allowed = true в Studio работает.
update public.app_users set allowed = true where email = 'stranger@example.com';
select pg_temp.login_as('00000000-0000-0000-0000-00000000000b', 'Stranger@Example.com');
select is(public.is_allowed(), true, 'stranger after allowed = true: is_allowed() = true');
reset role;

-- Без сессии вход не регистрируется.
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$ select public.register_login() $$, '42501', null, 'anon cannot call register_login');
reset role;
select throws_ok($$ select public.register_login() $$, '28000', 'not_authenticated',
  'register_login without a JWT email fails');

select * from finish();
rollback;
