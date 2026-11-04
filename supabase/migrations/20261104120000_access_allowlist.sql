-- Доступ: лист ожидания и отметка «разрешён» (ADR-0007, док 02 раздел 10).

create table public.app_users (
  id              uuid primary key default gen_random_uuid(),
  email           text not null unique check (email = lower(email)),
  user_id         uuid unique references auth.users (id) on delete set null,
  name            text,
  allowed         boolean not null default false,
  first_seen_at   timestamptz,
  last_attempt_at timestamptz,
  attempts        int not null default 0
);

-- С клиента таблица недоступна: только через RPC ниже.
alter table public.app_users enable row level security;
revoke all on public.app_users from anon, authenticated;

-- Вход: upsert по email из JWT, привязка user_id, счётчик попыток. Возвращает { allowed }.
create function public.register_login() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(auth.jwt() ->> 'email');
  v_name  text := coalesce(auth.jwt() -> 'user_metadata' ->> 'full_name',
                           auth.jwt() -> 'user_metadata' ->> 'name');
  v_allowed boolean;
begin
  if v_uid is null or v_email is null or v_email = '' then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  insert into public.app_users as u (email, user_id, name, first_seen_at, last_attempt_at, attempts)
  values (v_email, v_uid, v_name, now(), now(), 1)
  on conflict (email) do update
    set user_id         = excluded.user_id,
        name            = coalesce(excluded.name, u.name),
        first_seen_at   = coalesce(u.first_seen_at, excluded.first_seen_at),
        last_attempt_at = excluded.last_attempt_at,
        attempts        = u.attempts + 1
  returning u.allowed into v_allowed;

  return jsonb_build_object('allowed', v_allowed);
end $$;

revoke all on function public.register_login() from public, anon;
grant execute on function public.register_login() to authenticated;

-- Разрешён ли текущий пользователь. Входит в RLS каждой таблицы с данными (см. apply_user_rls ниже).
create function public.is_allowed() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select allowed from public.app_users where user_id = auth.uid()),
    false);
$$;

revoke all on function public.is_allowed() from public, anon;
grant execute on function public.is_allowed() to authenticated, service_role;

-- Владелец из ADMIN_EMAIL: upsert с allowed = true. Зовёт scripts/allow-owner.sh после
-- сброса базы и при деплое (SQL-сид не умеет читать env). Только service_role.
create function public.allow_owner(p_email text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_email is null or btrim(p_email) = '' then
    raise exception 'admin_email_empty' using errcode = '22023';
  end if;
  insert into public.app_users (email, allowed)
  values (lower(btrim(p_email)), true)
  on conflict (email) do update set allowed = true;
end $$;

revoke all on function public.allow_owner(text) from public, anon, authenticated;
grant execute on function public.allow_owner(text) to service_role;

-- Ошибка not_allowed для RPC: денежные функции зовут её первым шагом (ADR-0007, док 05).
create function public.assert_allowed() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_allowed() then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
end $$;

revoke all on function public.assert_allowed() from public, anon;
grant execute on function public.assert_allowed() to authenticated, service_role;

-- Правило доступа для таблицы с данными. Каждая новая таблица с колонкой user_id в миграции:
--   select public.apply_user_rls('public.<table>');
-- Включает RLS, ставит одну политику «свои строки и разрешён» на чтение и запись,
-- закрывает таблицу от anon. Какие действия вообще можно с клиента, решают GRANT'ы таблицы.
-- Тест 900_rls_guard падает, если таблица с user_id осталась без этого правила.
create function public.apply_user_rls(p_table regclass) returns void
language plpgsql as $$
begin
  execute format('alter table %s enable row level security', p_table);
  execute format('drop policy if exists user_rows on %s', p_table);
  execute format($p$
    create policy user_rows on %s as permissive for all to authenticated
      using      (user_id = (select auth.uid()) and (select public.is_allowed()))
      with check (user_id = (select auth.uid()) and (select public.is_allowed()))
  $p$, p_table);
  execute format('revoke all on %s from anon', p_table);
end $$;

revoke all on function public.apply_user_rls(regclass) from public, anon, authenticated, service_role;
