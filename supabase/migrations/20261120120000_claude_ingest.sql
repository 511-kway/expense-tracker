-- Тикет 20: вход для Claude Code (док 01 разделы 7–8, док 04 раздел 11, док 05 claude_ingest,
-- spec.md 93–94).
-- Служебный токен: 32 случайных байта (`etk_` + base64url), владелец получает его один раз при
-- выпуске; в базе только SHA-256 хэш (hex) и подсказка `etk_abcd…`. Один токен на владельца:
-- новый выпуск заменяет хэш, старый токен перестаёт работать сразу; отзыв удаляет строку. Срок год.
-- Edge Function claude_ingest считает хэш присланного токена и зовёт RPC claude_ingest ключом
-- service_role (только ему разрешено). RPC находит владельца по хэшу и на время вызова ставит его
-- id в JWT-настройки транзакции (auth.uid() = владелец), затем зовёт те же create_entry,
-- convert_note_to_entry, quick_capture, что экран: та же проверка, движок, пересчёт и лист
-- ожидания (assert_allowed для владельца). id пользователя из запроса не берётся никогда.
-- Ошибки не бросаются, а возвращаются {ok: false, error, details}: запись откатывается
-- подтранзакцией, а время последнего вызова и счётчик частоты сохраняются.

-- 1. Токены.
create table public.claude_tokens (
  user_id         uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  token_hash      text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  token_hint      text not null,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default now() + interval '1 year',
  last_used_at    timestamptz,
  -- Ограничение частоты: окно в минуту и число вызовов в нём.
  window_started_at timestamptz,
  window_calls    int not null default 0
);

-- Клиент только читает, и не хэш; пишут RPC ниже.
select public.apply_user_rls('public.claude_tokens');
revoke all on public.claude_tokens from authenticated;
grant select (user_id, token_hint, created_at, expires_at, last_used_at) on public.claude_tokens to authenticated;

-- 2. Выпуск (и смена) и отзыв токена владельцем. Ответ выпуска: { ok, token, token_hint,
-- expires_at }; токен больше нигде не хранится и повторно не показывается.
create function public.claude_token_generate() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_token text;
  t       public.claude_tokens;
begin
  perform public.assert_allowed();
  v_token := 'etk_' || rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into public.claude_tokens as c (user_id, token_hash, token_hint)
  values (auth.uid(), encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex'),
          substr(v_token, 1, 8) || '…')
  on conflict (user_id) do update
    set token_hash = excluded.token_hash, token_hint = excluded.token_hint, created_at = now(),
        expires_at = now() + interval '1 year', last_used_at = null, window_started_at = null, window_calls = 0
  returning * into t;
  return jsonb_build_object('ok', true, 'token', v_token, 'token_hint', t.token_hint, 'expires_at', t.expires_at);
end $$;

create function public.claude_token_revoke() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.assert_allowed();
  delete from public.claude_tokens where user_id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

-- 3. Что нужно Claude Code для разбора: счета, категории, новые заметки владельца.
create function engine.ingest_context(p_user uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'ok', true,
    'accounting_start_date', (select accounting_start_date from public.user_settings where user_id = p_user),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'type', a.type,
                            'currency', a.currency, 'start_date', a.start_date) order by a.name)
                          from public.accounts a where a.user_id = p_user and not a.is_archived), '[]'),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name)
                            from public.categories c where c.user_id = p_user and not c.is_archived), '[]'),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'text', n.text,
                         'attachment_path', n.attachment_path, 'created_at', n.created_at) order by n.created_at)
                       from public.notes n where n.user_id = p_user and n.status = 'new'), '[]'))
$$;

-- 4. Вход. p_request: { action: create_entry | convert_note | quick_capture | context,
-- payload?, note_id? }. Ответ RPC записи как есть ({ ok, entry_id, status, warnings, ... }) или
-- { ok: false, error, details }.
create function public.claude_ingest(p_token_hash text, p_request jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  t         public.claude_tokens;
  v_action  text := p_request ->> 'action';
  v_payload jsonb := p_request -> 'payload';
  v_claims  text := current_setting('request.jwt.claims', true);
  v_sub     text := current_setting('request.jwt.claim.sub', true);
  v_result  jsonb;
  v_msg     text;
  v_detail  text;
begin
  -- Поиск по уникальному индексу хэша: сравнивается хэш, а не сам токен, поэтому время ответа
  -- не подсказывает токен (подобрать вход хэша нельзя).
  select * into t from public.claude_tokens
  where token_hash = lower(p_token_hash) and expires_at > now()
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'token_invalid');
  end if;

  if t.window_started_at is null or t.window_started_at <= now() - interval '1 minute' then
    t.window_started_at := now();
    t.window_calls := 0;
  end if;
  if t.window_calls >= 60 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  update public.claude_tokens
  set last_used_at = now(), window_started_at = t.window_started_at, window_calls = t.window_calls + 1
  where user_id = t.user_id;

  -- Действуем как владелец: auth.uid() внутри RPC записи вернёт его id.
  perform set_config('request.jwt.claim.sub', t.user_id::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', t.user_id, 'role', 'authenticated')::text, true);
  begin
    if v_action = 'create_entry' then
      v_result := public.create_entry(v_payload);
    elsif v_action = 'convert_note' then
      if jsonb_typeof(p_request -> 'note_id') is distinct from 'string'
         or (p_request ->> 'note_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        perform engine.raise_error('field_invalid', '{"field": "note_id"}');
      end if;
      v_result := public.convert_note_to_entry((p_request ->> 'note_id')::uuid, v_payload);
    elsif v_action = 'quick_capture' then
      v_result := public.quick_capture(v_payload);
    elsif v_action = 'context' then
      perform public.assert_allowed();
      v_result := engine.ingest_context(t.user_id);
    else
      perform engine.raise_error('field_invalid', '{"field": "action"}');
    end if;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
    v_result := jsonb_build_object('ok', false, 'error', v_msg, 'details', engine.detail_json(v_detail));
  end;

  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  return v_result;
end $$;

-- Подробности ошибки: JSON из engine.raise_error; чужой текст (ошибка не движка) строкой.
create function engine.detail_json(p_detail text) returns jsonb
language plpgsql immutable as $$
begin
  if nullif(p_detail, '') is null then
    return '{}'::jsonb;
  end if;
  return p_detail::jsonb;
exception when others then
  return jsonb_build_object('text', p_detail);
end $$;

-- 5. Доступ к функциям: выпуск и отзыв владельцу, вход только service_role (Edge Function).
revoke all on function public.claude_token_generate(), public.claude_token_revoke() from public, anon;
grant execute on function public.claude_token_generate(), public.claude_token_revoke() to authenticated;
revoke all on function public.claude_ingest(text, jsonb) from public, anon, authenticated;
grant execute on function public.claude_ingest(text, jsonb) to service_role;

revoke all on all functions in schema engine from public;
