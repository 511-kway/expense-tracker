-- Страж ADR-0007: каждая таблица public с колонкой user_id закрыта правилом
-- «свои строки и разрешён» (public.apply_user_rls). Новая таблица без него валит этот тест.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

with data_tables as (
  select c.oid, c.relname, c.relrowsecurity
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p')
    and exists (select 1 from pg_attribute a
                where a.attrelid = c.oid and a.attname = 'user_id' and not a.attisdropped)
    and c.relname <> 'app_users'  -- лист ожидания: RLS без политик, только через RPC
)
select is(
  array(select relname::text from data_tables d
        where not relrowsecurity
           or exists (select 1 from pg_policy p where p.polrelid = d.oid
                      and (coalesce(pg_get_expr(p.polqual, p.polrelid), '') not like '%is_allowed()%'
                        or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), 'is_allowed()') not like '%is_allowed()%'))
           or not exists (select 1 from pg_policy p where p.polrelid = d.oid)
        order by 1),
  '{}'::text[],
  'every table with user_id has RLS with is_allowed() in every policy');

select is(
  (select relrowsecurity and not exists (select 1 from pg_policy where polrelid = c.oid)
   from pg_class c where c.oid = 'public.app_users'::regclass),
  true, 'app_users: RLS on, no client policies');

select * from finish();
rollback;
