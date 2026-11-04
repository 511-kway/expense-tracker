-- Заметки и вложения (док 02, разделы 6–7; док 03, раздел 9; док 04, разделы 4.2, 5, 6; док 05
-- convert_note_to_entry; spec.md): заметка текстом и/или скрином ни на что не влияет и ждёт в
-- инбоксе; «сделать запись» создаёт запись тем же путём, что create_entry, помечает заметку
-- разобранной и связывает их; вложения записи удаляются вместе с ней; файлы в Storage видит и
-- меняет только владелец (папка = его user id) и только разрешённый (ADR-0007).
-- Суммы в тиынах: 1 000 ₸ = 100 000.
begin;
create extension if not exists pgtap with schema extensions;
select plan(56);

create function pg_temp.uid(p_n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-' || lpad(p_n::text, 12, '0'))::uuid
$$;

create function pg_temp.login(p_n int) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid(p_n), 'role', 'authenticated')::text, true);
$$;

create function pg_temp.scenario(p_n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  insert into auth.users (id, email) values (pg_temp.uid(p_n), 'user' || p_n || '@example.com');
  insert into public.app_users (email, user_id, allowed) values ('user' || p_n || '@example.com', pg_temp.uid(p_n), true);
  perform pg_temp.login(p_n);
  perform public.setup_start('2026-11-01', 0, 0);
  perform public.create_category('Реклама');
end $$;

create function pg_temp.account(p_name text, p_total bigint default 0, p_company bigint default 0) returns uuid
language sql as $$
  select (public.create_account(p_name => p_name, p_type => 'card', p_start_date => '2026-11-01',
            p_total_minor => p_total, p_company_minor => p_company) ->> 'account_id')::uuid
$$;

create function pg_temp.acc(p_name text) returns uuid language sql as $$
  select account_id from public.v_account_balances where name = p_name
$$;

create function pg_temp.category() returns uuid language sql as $$
  select id from public.categories where name = 'Реклама'
$$;

-- Файл, загруженный в Storage (как его кладёт Storage API: строка storage.objects).
create function pg_temp.upload(p_path text) returns text language plpgsql as $$
declare v_role text := current_setting('role');
begin
  perform set_config('role', 'postgres', true);
  insert into storage.objects (bucket_id, name, owner) values ('files', p_path, null);
  perform set_config('role', v_role, true);
  return p_path;
end $$;

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

-- H1: всего 100 000 ₸, из них компании 50 000.
select pg_temp.scenario(1);
select pg_temp.account('H1', 10000000, 5000000);

-- Заметка только текстом: новая, на счётчики не влияет.
select set_config('test.n1', (public.create_note('Такси 2 500, Kaspi') ->> 'note_id'), true);
select results_eq(
  $$ select text, status::text, attachment_path, linked_entry_id from public.notes
     where id = current_setting('test.n1')::uuid $$,
  $$ values ('Такси 2 500, Kaspi'::text, 'new'::text, null::text, null::uuid) $$,
  'text note is saved as new');

select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 5000000::bigint, 0::bigint, 0::bigint) $$,
  'a note does not change the counters');
select public.recompute();
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (10000000::bigint, 5000000::bigint, 0::bigint, 0::bigint) $$,
  'a note stays out of a full recompute');

-- Заметка скрином: файл в своей папке.
select pg_temp.upload(pg_temp.uid(1) || '/notes/shot.png');
select set_config('test.n2', (public.create_note(null, pg_temp.uid(1) || '/notes/shot.png') ->> 'note_id'), true);
select results_eq(
  $$ select text, attachment_path, status::text from public.notes where id = current_setting('test.n2')::uuid $$,
  $$ values (null::text, pg_temp.uid(1) || '/notes/shot.png', 'new'::text) $$,
  'screenshot-only note is saved as new');

-- Инбокс: новые заметки рядом с черновиками и тратами без категории; бейдж считает их.
select results_eq(
  $$ select kind, entry_id, note_text, note_attachment_path from public.v_inbox order by created_at $$,
  $$ values ('note'::text, null::uuid, 'Такси 2 500, Kaspi'::text, null::text),
            ('note', null, null, pg_temp.uid(1) || '/notes/shot.png') $$,
  'new notes wait in the inbox');
select is((select items from public.v_inbox_count), 2, 'inbox badge counts new notes');
select results_eq(
  $$ select note_id from public.v_inbox order by created_at $$,
  $$ values (current_setting('test.n1')::uuid), (current_setting('test.n2')::uuid) $$,
  'inbox note rows carry the note id');

-- Ошибки заметки.
select is(pg_temp.error_of($$ select public.create_note('   ') $$),
  '{"code": "note_empty", "detail": {}}'::jsonb, 'note needs text or a screenshot');
select is(pg_temp.error_of($$ select public.create_note(null, pg_temp.uid(1) || '/notes/missing.png') $$),
  jsonb_build_object('code', 'file_not_found', 'detail', jsonb_build_object('path', pg_temp.uid(1) || '/notes/missing.png')),
  'note screenshot must be uploaded first');
select pg_temp.upload(pg_temp.uid(2) || '/notes/alien.png');
select is(pg_temp.error_of($$ select public.create_note(null, pg_temp.uid(2) || '/notes/alien.png') $$) ->> 'code',
  'file_not_found', 'note cannot point at a file in another user''s folder');
select throws_ok($$ insert into public.notes (user_id, text) values (pg_temp.uid(1), 'напрямую') $$,
  '42501', null, 'client cannot write notes directly');

-- «Сделать запись» из заметки: работа 2 500 ₸ с H1 (тратит аванс), через тот же путь, что create_entry.
create function pg_temp.work_expense(p_amount bigint, p_title text) returns jsonb language sql as $$
  select jsonb_build_object('type', 'expense', 'occurred_on', '2026-11-02', 'amount_minor', p_amount,
    'account_id', pg_temp.acc('H1'), 'purpose', 'work', 'category_id', pg_temp.category(), 'title', p_title)
$$;

select set_config('test.c1', public.convert_note_to_entry(current_setting('test.n1')::uuid,
  pg_temp.work_expense(250000, 'Такси')) ::text, true);
select results_eq(
  $$ select current_setting('test.c1')::jsonb ->> 'status', (current_setting('test.c1')::jsonb ->> 'note_id')::uuid $$,
  $$ values ('done'::text, current_setting('test.n1')::uuid) $$,
  'convert note: the entry is saved as done');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9750000::bigint, 4750000::bigint, 0::bigint, 0::bigint) $$,
  'entry from a note is counted like any entry');
select results_eq(
  $$ select n.status::text, n.linked_entry_id, e.source_note_id
     from public.notes n join public.entries e on e.id = n.linked_entry_id
     where n.id = current_setting('test.n1')::uuid $$,
  $$ values ('processed'::text, (current_setting('test.c1')::jsonb ->> 'entry_id')::uuid,
             current_setting('test.n1')::uuid) $$,
  'converted note is processed and linked to its entry both ways');
select is((select count(*)::int from public.v_inbox where note_id = current_setting('test.n1')::uuid), 0,
  'processed note leaves the inbox');

-- Любой тип записи: поступление из заметки скрином; скрин становится вложением записи.
select set_config('test.c2', public.convert_note_to_entry(current_setting('test.n2')::uuid,
  jsonb_build_object('type', 'income', 'occurred_on', '2026-11-02', 'amount_minor', 100000,
    'account_id', pg_temp.acc('H1'), 'title', 'Кэшбэк'))::text, true);
select results_eq(
  $$ select e.type::text, a.file_path, a.kind from public.entries e
     join public.attachments a on a.entry_id = e.id
     where e.id = (current_setting('test.c2')::jsonb ->> 'entry_id')::uuid $$,
  $$ values ('income'::text, pg_temp.uid(1) || '/notes/shot.png', 'screenshot'::text) $$,
  'convert any type; the note screenshot is attached to the entry');
select is((select items from public.v_inbox_count), 0, 'inbox is empty once notes are processed');

-- Разобранную заметку второй раз не разбирают.
select is(pg_temp.error_of($$ select public.convert_note_to_entry(current_setting('test.n1')::uuid,
    pg_temp.work_expense(100, 'Ещё')) $$),
  jsonb_build_object('code', 'note_already_processed', 'detail',
    jsonb_build_object('note_id', current_setting('test.n1')::uuid,
                       'entry_id', (current_setting('test.c1')::jsonb ->> 'entry_id')::uuid)),
  'processed note cannot be converted again');

-- Атомарно: запись не прошла проверку = заметка осталась новой, записи нет.
select set_config('test.n3', (public.create_note('Кофе') ->> 'note_id'), true);
select is(pg_temp.error_of($$ select public.convert_note_to_entry(current_setting('test.n3')::uuid,
    pg_temp.work_expense(100, 'Кофе') - 'category_id') $$),
  '{"code": "missing_required", "detail": {"field": "category_id"}}'::jsonb,
  'convert uses the full-form checks of create_entry');
select results_eq(
  $$ select n.status::text, n.linked_entry_id, (select count(*) from public.entries where title = 'Кофе')
     from public.notes n where n.id = current_setting('test.n3')::uuid $$,
  $$ values ('new'::text, null::uuid, 0::bigint) $$,
  'failed convert leaves the note new and creates nothing');
select is(pg_temp.error_of($$ select public.convert_note_to_entry(gen_random_uuid(), '{}') $$) ->> 'code',
  'note_not_found', 'unknown note: note_not_found');

-- Ссылку на заметку ставит только разбор: create_entry её отбрасывает, правка сохраняет.
select set_config('test.e4', public.create_entry(pg_temp.work_expense(100, 'Подмена')
  || jsonb_build_object('source_note_id', current_setting('test.n3')))::text, true);
select is((select source_note_id from public.entries where id = (current_setting('test.e4')::jsonb ->> 'entry_id')::uuid),
  null, 'create_entry ignores a client source_note_id');
select public.update_entry((current_setting('test.c1')::jsonb ->> 'entry_id')::uuid,
  pg_temp.work_expense(300000, 'Такси до офиса'));
select is((select source_note_id from public.entries where id = (current_setting('test.c1')::jsonb ->> 'entry_id')::uuid),
  current_setting('test.n1')::uuid, 'editing the entry keeps its link to the note');

-- Вложения записи: чек к записи из заметки (там уже нет вложений) и к записи «Подмена».
select set_config('test.e1', current_setting('test.c1')::jsonb ->> 'entry_id', true);
select pg_temp.upload(pg_temp.uid(1) || '/entries/receipt.jpg');
select set_config('test.a1', (public.add_attachment(current_setting('test.e1')::uuid,
  pg_temp.uid(1) || '/entries/receipt.jpg', 'receipt', 'чек.jpg') ->> 'attachment_id'), true);
select results_eq(
  $$ select entry_id, file_path, file_name, kind from public.attachments where id = current_setting('test.a1')::uuid $$,
  $$ values (current_setting('test.e1')::uuid, pg_temp.uid(1) || '/entries/receipt.jpg', 'чек.jpg'::text, 'receipt'::text) $$,
  'attachment is linked to the entry');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9799900::bigint, 4699900::bigint, 0::bigint, 0::bigint) $$,
  'attachments do not change the counters');
select is(pg_temp.error_of($$ select public.add_attachment(current_setting('test.e1')::uuid,
    pg_temp.uid(1) || '/entries/receipt.jpg', 'selfie') $$),
  '{"code": "field_invalid", "detail": {"field": "kind"}}'::jsonb, 'attachment kind is receipt, screenshot or invoice');
select is(pg_temp.error_of($$ select public.add_attachment(current_setting('test.e1')::uuid,
    pg_temp.uid(2) || '/notes/alien.png') $$) ->> 'code',
  'file_not_found', 'attachment cannot point at another user''s file');
select is(pg_temp.error_of($$ select public.add_attachment(gen_random_uuid(),
    pg_temp.uid(1) || '/entries/receipt.jpg') $$) ->> 'code',
  'entry_not_found', 'attachment needs an own entry');

-- Удалить одно вложение: строка уходит, путь файла клиенту на удаление из Storage.
select pg_temp.upload(pg_temp.uid(1) || '/entries/extra.pdf');
select set_config('test.a2', (public.add_attachment(current_setting('test.e1')::uuid,
  pg_temp.uid(1) || '/entries/extra.pdf', 'invoice') ->> 'attachment_id'), true);
select is(public.delete_attachment(current_setting('test.a2')::uuid),
  jsonb_build_object('ok', true, 'removed_files', jsonb_build_array(pg_temp.uid(1) || '/entries/extra.pdf')),
  'delete attachment returns the file to remove from storage');
select is(pg_temp.error_of($$ select public.delete_attachment(current_setting('test.a2')::uuid) $$) ->> 'code',
  'attachment_not_found', 'deleted attachment is gone');

-- Удаление записи: вложения уходят вместе с ней, файлы клиенту на удаление; скрин, на который
-- ещё ссылается заметка, остаётся. Заметка, из которой запись сделана, снова новая.
select pg_temp.upload(pg_temp.uid(1) || '/entries/receipt2.jpg');
select public.add_attachment((current_setting('test.c2')::jsonb ->> 'entry_id')::uuid,
  pg_temp.uid(1) || '/entries/receipt2.jpg');
select is(public.delete_entry((current_setting('test.c2')::jsonb ->> 'entry_id')::uuid) -> 'removed_files',
  jsonb_build_array(pg_temp.uid(1) || '/entries/receipt2.jpg'),
  'delete entry returns its attachment files, except one a note still uses');
select is((select count(*)::int from public.attachments where entry_id = (current_setting('test.c2')::jsonb ->> 'entry_id')::uuid),
  0, 'deleting the entry deletes its attachments');
select results_eq(
  $$ select status::text, linked_entry_id from public.notes where id = current_setting('test.n2')::uuid $$,
  $$ values ('new'::text, null::uuid) $$,
  'deleting the entry made from a note returns the note to new');
select results_eq($$ select * from pg_temp.state('H1') $$,
  $$ values (9699900::bigint, 4699900::bigint, 0::bigint, 0::bigint) $$,
  'deleting the entry recomputes the counters');

-- Удалить заметку: её скрин клиенту на удаление; запись из заметки остаётся без ссылки.
select is(public.delete_note(current_setting('test.n2')::uuid),
  jsonb_build_object('ok', true, 'removed_files', jsonb_build_array(pg_temp.uid(1) || '/notes/shot.png')),
  'delete note returns its screenshot to remove');
select public.delete_note(current_setting('test.n1')::uuid);
select results_eq(
  $$ select source_note_id, (select count(*) from public.attachments a where a.entry_id = e.id)
     from public.entries e where e.id = current_setting('test.e1')::uuid $$,
  $$ values (null::uuid, 1::bigint) $$,
  'entry made from a deleted note stays, with its attachments');
select is(pg_temp.error_of($$ select public.delete_note(current_setting('test.n1')::uuid) $$) ->> 'code',
  'note_not_found', 'deleted note is gone');

-- Подчистка: свои файлы без ссылок старше суток (клиент не успел удалить).
set local role postgres;
update storage.objects set created_at = now() - interval '2 days';
select pg_temp.login(1);
select results_eq($$ select name from public.v_orphan_files order by name $$,
  $$ values (pg_temp.uid(1) || '/entries/extra.pdf'), (pg_temp.uid(1) || '/entries/receipt2.jpg'),
            (pg_temp.uid(1) || '/notes/shot.png') $$,
  'orphan files: own files no note or attachment uses');

-- Хранилище (ADR-0007): политики storage.objects пускают только в свою папку и только разрешённого.
select pg_temp.login(1);
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('files', pg_temp.uid(1) || '/notes/own.png') $$,
  'storage: owner uploads into own folder');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('files', pg_temp.uid(2) || '/notes/planted.png') $$,
  '42501', null, 'storage: cannot upload into another user''s folder');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('files', 'shared/loose.png') $$,
  '42501', null, 'storage: cannot upload outside a user folder');
select is((select count(*)::int from storage.objects where name like pg_temp.uid(2) || '/%'), 0,
  'storage: cannot see another user''s files');
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects where name like pg_temp.uid(2) || '/%';
update storage.objects set name = pg_temp.uid(1) || '/stolen.png' where name like pg_temp.uid(2) || '/%';
select is((select count(*)::int from storage.objects where name like pg_temp.uid(1) || '/%'), 5,
  'storage: sees own files');
delete from storage.objects where name = pg_temp.uid(1) || '/notes/own.png';
set local role postgres;
select results_eq(
  $$ select count(*) filter (where name like pg_temp.uid(2) || '/%'),
            count(*) filter (where name = pg_temp.uid(1) || '/notes/own.png') from storage.objects $$,
  $$ values (1::bigint, 0::bigint) $$,
  'storage: another user''s files untouched, own file deleted');

-- Второй пользователь: свои заметки и вложения не видит чужих, файлы владельца ему закрыты.
select pg_temp.scenario(2);
select results_eq(
  $$ select (select count(*) from public.notes), (select count(*) from public.attachments),
            (select items from public.v_inbox_count)::bigint, (select count(*) from storage.objects) $$,
  $$ values (0::bigint, 0::bigint, 0::bigint, 1::bigint) $$,
  'another user sees only own notes, attachments and files');
select is(pg_temp.error_of(format('select public.convert_note_to_entry(%L, %L)',
    current_setting('test.n3'), '{}')) ->> 'code',
  'note_not_found', 'another user''s note: note_not_found');
select is(pg_temp.error_of(format('select public.delete_attachment(%L)', current_setting('test.a1'))) ->> 'code',
  'attachment_not_found', 'another user''s attachment: attachment_not_found');

-- Неразрешённый с действующей сессией: ни заметок, ни файлов, даже своих.
set local role postgres;
insert into auth.users (id, email) values (pg_temp.uid(3), 'stranger@example.com');
insert into public.app_users (email, user_id, allowed) values ('stranger@example.com', pg_temp.uid(3), false);
insert into storage.objects (bucket_id, name) values ('files', pg_temp.uid(3) || '/notes/x.png');
select pg_temp.login(3);
select is((select count(*)::int from storage.objects), 0, 'not allowed: sees no files, not even own');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('files', pg_temp.uid(3) || '/notes/y.png') $$,
  '42501', null, 'not allowed: cannot upload into own folder');
select throws_ok($$ select public.create_note('x') $$, '42501', 'not_allowed', 'not allowed: create_note');
select throws_ok($$ select public.delete_note(gen_random_uuid()) $$, '42501', 'not_allowed', 'not allowed: delete_note');
select throws_ok($$ select public.convert_note_to_entry(gen_random_uuid(), '{}') $$, '42501', 'not_allowed',
  'not allowed: convert_note_to_entry');
select throws_ok($$ select public.add_attachment(gen_random_uuid(), 'x') $$, '42501', 'not_allowed',
  'not allowed: add_attachment');
select throws_ok($$ select public.delete_attachment(gen_random_uuid()) $$, '42501', 'not_allowed',
  'not allowed: delete_attachment');

-- Аноним файлов не видит.
set local role anon;
select is((select count(*)::int from storage.objects), 0, 'anon: sees no files');
reset role;

-- Бакет приватный, с лимитом размера и типов.
select results_eq(
  $$ select public, file_size_limit, allowed_mime_types @> array['image/jpeg', 'image/png', 'application/pdf'],
            'text/html' = any(allowed_mime_types) from storage.buckets where id = 'files' $$,
  $$ values (false, 20971520::bigint, true, false) $$,
  'files bucket is private, limited to 20 MiB of images and PDF');

select * from finish();
rollback;
