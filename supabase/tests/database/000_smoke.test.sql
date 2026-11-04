-- Smoke: база поднимается из миграций, pgTAP доступен.
begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

select ok(true, 'database is up');
select is(current_setting('server_version_num')::int >= 170000, true, 'Postgres 17+');

select * from finish();
rollback;
