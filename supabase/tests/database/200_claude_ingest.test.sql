-- Вход для Claude Code (док 01 разделы 7–8, док 04 раздел 11, док 05 claude_ingest, spec.md 93–94).
-- Служебный токен хранится только как SHA-256 хэш; Edge Function claude_ingest считает хэш и зовёт
-- RPC claude_ingest ключом service_role. RPC находит владельца по хэшу и создаёт запись под ним той
-- же функцией, что create_entry / convert_note_to_entry (та же проверка, движок, пересчёт, лист
-- ожидания). Смена токена: старый перестаёт работать сразу.
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(41);

create function pg_temp.uid(p_n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid
$$;

create function pg_temp.login(p_n int) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid(p_n), 'role', 'authenticated')::text, true);
$$;

-- Как Edge Function: роль service_role, в JWT нет пользователя.
create function pg_temp.as_service() returns void language sql as $$
  select set_config('role', 'service_role', true),
         set_config('request.jwt.claims', '{"role": "service_role"}', true);
$$;

create function pg_temp.scenario(p_n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (pg_temp.uid(p_n), 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', pg_temp.uid(p_n), true);
  perform pg_temp.login(p_n);
  perform public.setup_start('2026-11-01', 0, 0);
  perform public.create_category('Такси');
end $$;

create function pg_temp.sha256(p_token text) returns text language sql as $$
  select encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
$$;

create function pg_temp.ingest(p_token text, p_request jsonb) returns jsonb language sql as $$
  select public.claude_ingest(pg_temp.sha256(p_token), p_request)
$$;

-- Остаток счёта глазами владельца 1 (выборка по auth.uid()), затем снова роль Edge Function.
create function pg_temp.balance(p_account text) returns bigint language plpgsql as $$
declare v bigint;
begin
  perform pg_temp.login(1);
  select balance_minor into v from public.v_account_balances where name = p_account;
  perform pg_temp.as_service();
  return v;
end $$;

-- Владелец 1: счёт Kaspi 100 000 ₸ своих, токен для Claude Code.
select pg_temp.scenario(1);
select set_config('test.acc', (public.create_account(p_name => 'Kaspi', p_type => 'card',
  p_start_date => '2026-11-01', p_total_minor => 10000000, p_company_minor => 0) ->> 'account_id'), true);
select set_config('test.cat', (select id::text from public.categories where name = 'Такси'), true);

create function pg_temp.expense(p_amount bigint) returns jsonb language sql as $$
  select jsonb_build_object('type', 'expense', 'occurred_on', '2026-11-02', 'amount_minor', p_amount,
    'account_id', current_setting('test.acc'), 'purpose', 'personal', 'source', 'own',
    'category_id', current_setting('test.cat'), 'title', 'Такси')
$$;

select set_config('test.t1', public.claude_token_generate() ->> 'token', true);

-- Токен показывается один раз; в базе только хэш.
select ok(current_setting('test.t1') ~ '^etk_[A-Za-z0-9_-]{43}$', 'token is etk_ + 32 random bytes in base64url');
set local role postgres;
select is((select token_hash from public.claude_tokens where user_id = pg_temp.uid(1)),
  pg_temp.sha256(current_setting('test.t1')), 'only the SHA-256 hash of the token is stored');
select is((select count(*)::int from public.claude_tokens t
           where to_jsonb(t)::text like '%' || substr(current_setting('test.t1'), 5) || '%'), 0,
  'the token itself is stored nowhere in the row');
select pg_temp.login(1);
select throws_ok($$ select token_hash from public.claude_tokens $$, '42501', null,
  'the owner cannot read the hash back');
select results_eq($$ select token_hint, last_used_at from public.claude_tokens $$,
  $$ values ('etk_' || substr(current_setting('test.t1'), 5, 4) || '…', null::timestamptz) $$,
  'the owner sees the token hint and when it was last used');
select throws_ok($$ insert into public.claude_tokens (user_id, token_hash, token_hint)
                    values (pg_temp.uid(1), 'x', 'x') $$, '42501', null, 'client cannot write tokens directly');

-- Кто может звать вход: только service_role.
select is(has_function_privilege('authenticated', 'public.claude_ingest(text, jsonb)', 'execute'), false,
  'authenticated cannot call claude_ingest');
select is(has_function_privilege('anon', 'public.claude_ingest(text, jsonb)', 'execute'), false,
  'anon cannot call claude_ingest');
select is(has_function_privilege('service_role', 'public.claude_ingest(text, jsonb)', 'execute'), true,
  'service_role calls claude_ingest');
select throws_ok(format('select public.claude_ingest(%L, %L)', pg_temp.sha256(current_setting('test.t1')),
  jsonb_build_object('action', 'create_entry', 'payload', pg_temp.expense(250000))),
  '42501', null, 'the owner session itself cannot use the ingest RPC');
select is(has_function_privilege('anon', 'public.claude_token_generate()', 'execute'), false,
  'anon cannot generate a token');

-- Верный токен: запись создаётся под владельцем тем же путём, что create_entry.
select pg_temp.as_service();
select set_config('test.r1', pg_temp.ingest(current_setting('test.t1'),
  jsonb_build_object('action', 'create_entry', 'payload', pg_temp.expense(250000)))::text, true);
select results_eq(
  $$ select (current_setting('test.r1')::jsonb ->> 'ok')::boolean, current_setting('test.r1')::jsonb ->> 'status',
            current_setting('test.r1')::jsonb -> 'warnings' $$,
  $$ values (true, 'done'::text, '[]'::jsonb) $$,
  'good token creates the entry: ok, status, warnings like create_entry');
select is((select user_id from public.entries where id = (current_setting('test.r1')::jsonb ->> 'entry_id')::uuid),
  pg_temp.uid(1), 'the entry belongs to the token owner');
select is(pg_temp.balance('Kaspi'), 9750000::bigint, 'the entry is counted: 100 000 − 2 500 = 97 500 ₸');
select isnt((select last_used_at from public.claude_tokens where user_id = pg_temp.uid(1)), null,
  'last used time is recorded');
select is(auth.uid(), null, 'the acting user does not outlive the call');

-- Неверный токен: отказ, ничего не создано.
select is(pg_temp.ingest('etk_wrong', jsonb_build_object('action', 'create_entry', 'payload', pg_temp.expense(100))),
  '{"ok": false, "error": "token_invalid"}'::jsonb, 'wrong token is rejected');
select is(public.claude_ingest(null, '{"action": "create_entry"}'),
  '{"ok": false, "error": "token_invalid"}'::jsonb, 'missing token is rejected');
select is(pg_temp.balance('Kaspi'), 9750000::bigint, 'rejected call changes nothing');

-- Ошибки проверки приходят теми же кодами, что у create_entry; запись не создаётся.
select is(pg_temp.ingest(current_setting('test.t1'),
  jsonb_build_object('action', 'create_entry', 'payload', pg_temp.expense(0))),
  '{"ok": false, "error": "amount_not_positive", "details": {}}'::jsonb, 'validation error is passed through');
select is(pg_temp.ingest(current_setting('test.t1'),
  jsonb_build_object('action', 'create_entry', 'payload', pg_temp.expense(100) - 'category_id')) ->> 'error',
  'missing_required', 'full form rules: category is required');
select is(pg_temp.ingest(current_setting('test.t1'),
  jsonb_build_object('action', 'create_entry', 'payload',
    pg_temp.expense(100) || '{"occurred_on": "2026-10-01"}')) ->> 'error',
  'entry_before_start', 'engine rules apply: no entry before the start date');
select is(pg_temp.ingest(current_setting('test.t1'), '{"action": "launch"}'),
  '{"ok": false, "error": "field_invalid", "details": {"field": "action"}}'::jsonb, 'unknown action is field_invalid');
select is(pg_temp.balance('Kaspi'), 9750000::bigint, 'failed calls create nothing');

-- Заметка → запись (convert_note_to_entry): заметка разобрана и связана.
select pg_temp.login(1);
select set_config('test.n1', public.create_note('Такси 1 000, Kaspi') ->> 'note_id', true);
select pg_temp.as_service();
select set_config('test.r2', pg_temp.ingest(current_setting('test.t1'),
  jsonb_build_object('action', 'convert_note', 'note_id', current_setting('test.n1'),
    'payload', pg_temp.expense(100000)))::text, true);
select results_eq(
  $$ select n.status::text, n.linked_entry_id, e.source_note_id from public.notes n
     join public.entries e on e.id = n.linked_entry_id where n.id = current_setting('test.n1')::uuid $$,
  $$ values ('processed'::text, (current_setting('test.r2')::jsonb ->> 'entry_id')::uuid,
             current_setting('test.n1')::uuid) $$,
  'convert_note: the note is processed and linked to its entry');
select is(current_setting('test.r2')::jsonb ->> 'note_id', current_setting('test.n1'), 'answer carries note_id');
select is(pg_temp.balance('Kaspi'), 9650000::bigint, '97 500 − 1 000 = 96 500 ₸');
select is(pg_temp.ingest(current_setting('test.t1'),
  jsonb_build_object('action', 'convert_note', 'note_id', current_setting('test.n1'),
    'payload', pg_temp.expense(100000))) ->> 'error',
  'note_already_processed', 'a processed note is not converted twice');

-- Быстрый ввод (ADR-0009): трата без категории, учтённая сразу.
select is(pg_temp.ingest(current_setting('test.t1'),
  jsonb_build_object('action', 'quick_capture', 'payload',
    jsonb_build_object('amount_minor', 50000, 'account_id', current_setting('test.acc'),
      'purpose', 'work', 'occurred_on', '2026-11-03', 'title', 'Обед'))) ->> 'status',
  'done', 'quick_capture through the same RPC');

-- Контекст для разбора: счета, категории, новые заметки владельца.
select pg_temp.login(1);
select public.create_note('Кофе 900');
select pg_temp.as_service();
select set_config('test.ctx', pg_temp.ingest(current_setting('test.t1'), '{"action": "context"}')::text, true);
select results_eq(
  $$ select jsonb_path_query_array(current_setting('test.ctx')::jsonb, '$.accounts[*].name'),
            jsonb_path_query_array(current_setting('test.ctx')::jsonb, '$.categories[*].name'),
            jsonb_path_query_array(current_setting('test.ctx')::jsonb, '$.notes[*].text'),
            current_setting('test.ctx')::jsonb ->> 'accounting_start_date' $$,
  $$ values ('["Kaspi"]'::jsonb, '["Такси"]'::jsonb, '["Кофе 900"]'::jsonb, '2026-11-01'::text) $$,
  'context lists accounts, categories and new notes of the owner');

-- Владелец 2 со своим токеном не видит и не трогает данные владельца 1.
select pg_temp.scenario(2);
select set_config('test.t2', public.claude_token_generate() ->> 'token', true);
select pg_temp.login(1);
select set_config('test.n2', public.create_note('Чужая заметка') ->> 'note_id', true);
select pg_temp.as_service();
select is(pg_temp.ingest(current_setting('test.t2'),
  jsonb_build_object('action', 'convert_note', 'note_id', current_setting('test.n2'),
    'payload', pg_temp.expense(100))) ->> 'error',
  'note_not_found', 'another owner''s token cannot convert my note');
select is(pg_temp.ingest(current_setting('test.t2'),
  jsonb_build_object('action', 'create_entry', 'payload', pg_temp.expense(100))) ->> 'error',
  'account_not_found', 'another owner''s token cannot use my account');
select is(jsonb_array_length(pg_temp.ingest(current_setting('test.t2'), '{"action": "context"}') -> 'notes'), 0,
  'context of owner 2 has none of my notes');

-- Лист ожидания действует и здесь: снятый с доступа владелец не пишет даже с токеном.
set local role postgres;
update public.app_users set allowed = false where user_id = pg_temp.uid(2);
select pg_temp.as_service();
select is(pg_temp.ingest(current_setting('test.t2'), '{"action": "context"}') ->> 'error',
  'not_allowed', 'allowlist is enforced for the token owner');

-- Смена токена: старый перестаёт работать, новый работает.
select pg_temp.login(1);
select set_config('test.t1b', public.claude_token_generate() ->> 'token', true);
select pg_temp.as_service();
select is(pg_temp.ingest(current_setting('test.t1'), '{"action": "context"}') ->> 'error',
  'token_invalid', 'after rotation the old token stops working');
select is((pg_temp.ingest(current_setting('test.t1b'), '{"action": "context"}') ->> 'ok')::boolean, true,
  'the new token works');
select is((select count(*)::int from public.claude_tokens where user_id = pg_temp.uid(1)), 1,
  'one token per owner');

-- Срок: истёкший токен не работает.
set local role postgres;
update public.claude_tokens set expires_at = now() - interval '1 second' where user_id = pg_temp.uid(1);
select pg_temp.as_service();
select is(pg_temp.ingest(current_setting('test.t1b'), '{"action": "context"}') ->> 'error',
  'token_invalid', 'expired token is rejected');

-- Ограничение частоты: не больше 60 вызовов в минуту на токен.
select pg_temp.login(1);
select set_config('test.t1c', public.claude_token_generate() ->> 'token', true);
select pg_temp.as_service();
select pg_temp.ingest(current_setting('test.t1c'), '{"action": "context"}') from generate_series(1, 60);
select is(pg_temp.ingest(current_setting('test.t1c'), '{"action": "context"}') ->> 'error',
  'rate_limited', '61st call within a minute is rate_limited');

-- Отзыв: токен удалён, вход закрыт.
select pg_temp.login(1);
select is(public.claude_token_revoke(), '{"ok": true}'::jsonb, 'owner revokes the token');
select pg_temp.as_service();
select is(pg_temp.ingest(current_setting('test.t1c'), '{"action": "context"}') ->> 'error',
  'token_invalid', 'revoked token is rejected');

select * from finish();
rollback;
