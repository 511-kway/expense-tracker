-- TC-WAITLIST + TC-RLS (док 06, раздел 12; ADR-0007): правило доступа к таблицам с данными.
-- Проверяется на пробной таблице, оформленной так же, как будущие таблицы с данными:
-- колонка user_id и public.apply_user_rls(). Таблица живёт только внутри этой транзакции.
begin;
create extension if not exists pgtap with schema extensions;
select plan(10);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'owner@example.com'),
  ('00000000-0000-0000-0000-00000000000b', 'second@example.com'),
  ('00000000-0000-0000-0000-00000000000c', 'stranger@example.com');
insert into public.app_users (email, user_id, allowed) values
  ('owner@example.com',    '00000000-0000-0000-0000-00000000000a', true),
  ('second@example.com',   '00000000-0000-0000-0000-00000000000b', true),
  ('stranger@example.com', '00000000-0000-0000-0000-00000000000c', false);

create table public.rls_probe (
  id      bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id),
  note    text
);
grant select, insert, update, delete on public.rls_probe to authenticated;
select public.apply_user_rls('public.rls_probe');

insert into public.rls_probe (user_id, note) values
  ('00000000-0000-0000-0000-00000000000a', 'owner row'),
  ('00000000-0000-0000-0000-00000000000b', 'second row'),
  ('00000000-0000-0000-0000-00000000000c', 'stranger row');

create function pg_temp.login_as(uid uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims',
           json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;

-- Неразрешённый с действующей сессией: ничего не читает и не пишет, даже свои строки.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000c');
select is((select count(*) from public.rls_probe), 0::bigint, 'not allowed: reads nothing, not even own rows');
select throws_ok($$ insert into public.rls_probe (note) values ('x') $$, '42501', null,
  'not allowed: cannot insert own row');
update public.rls_probe set note = 'hacked';
delete from public.rls_probe;
reset role;
select is((select count(*) from public.rls_probe where note in ('owner row', 'second row', 'stranger row')),
  3::bigint, 'not allowed: update and delete touched nothing');

-- Разрешённый: видит и меняет только свои строки.
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select results_eq($$ select note from public.rls_probe $$, $$ values ('owner row'::text) $$,
  'allowed: sees only own rows');
select lives_ok($$ insert into public.rls_probe (note) values ('owner new') $$, 'allowed: inserts own row');
select throws_ok($$ insert into public.rls_probe (user_id, note)
                    values ('00000000-0000-0000-0000-00000000000b', 'planted') $$, '42501', null,
  'allowed: cannot insert a row for another user');
select throws_ok($$ update public.rls_probe set user_id = '00000000-0000-0000-0000-00000000000b' $$,
  '42501', null, 'allowed: cannot hand own row to another user');
update public.rls_probe set note = 'hacked' where user_id = '00000000-0000-0000-0000-00000000000b';
delete from public.rls_probe where user_id = '00000000-0000-0000-0000-00000000000b';
reset role;
select is((select note from public.rls_probe where user_id = '00000000-0000-0000-0000-00000000000b'),
  'second row', 'allowed: cannot update or delete another user''s rows');

-- Отметку сняли: доступ пропадает сразу, без выхода из сессии.
update public.app_users set allowed = false where email = 'owner@example.com';
select pg_temp.login_as('00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.rls_probe), 0::bigint, 'flag removed: reads nothing with a live session');
reset role;

-- Аноним (ключ без сессии) таблицу не видит вовсе.
set local role anon;
select throws_ok($$ select * from public.rls_probe $$, '42501', null, 'anon: no access');
reset role;

select * from finish();
rollback;
