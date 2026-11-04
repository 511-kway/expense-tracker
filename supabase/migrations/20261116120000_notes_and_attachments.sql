-- Тикет 16: заметки и вложения (док 02, разделы 6–7; док 03, раздел 9; док 04, разделы 4.2, 5, 6;
-- док 05 convert_note_to_entry; spec.md).
-- Заметка = текст и/или скрин, не запись: на остаток, аванс и долг не влияет никогда и ждёт в
-- инбоксе, пока новая. «Сделать запись» (convert_note_to_entry) создаёт запись тем же путём, что
-- create_entry (любой тип), ставит ей source_note_id, а заметке processed и linked_entry_id,
-- одной транзакцией. Вложения (чек, скрин, PDF) привязаны к записи и удаляются вместе с ней.
-- Файлы лежат в приватном бакете Storage `files`, путь `<user_id>/...`: политики storage.objects
-- пускают только в свою папку и только разрешённого (ADR-0007).
-- Файл в Storage SQL удалить не может (Storage API запрещает DELETE из storage.objects мимо себя),
-- поэтому RPC, которые убирают строки заметок и вложений, возвращают removed_files: пути, на
-- которые больше никто не ссылается; клиент удаляет их через Storage API. Страховка, если клиент
-- не успел: v_orphan_files (свои файлы без ссылок старше суток), клиент подчищает их сам.
-- Скопированы с последнего определения: create_entry и engine.update_entry
-- (20261115120000_quick_capture.sql), delete_entry (20261112120000_refunds.sql), v_inbox
-- (20261115120000_quick_capture.sql); прежние ветки на месте.

-- 1. Хранилище: приватный бакет, лимит размера и типы файлов (скрины, фото чеков, PDF).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('files', 'files', false, 20971520,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'image/gif', 'application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Только своя папка (первый сегмент пути = свой user id) и только разрешённому, на все действия.
create policy files_owner on storage.objects as permissive for all to authenticated
  using (bucket_id = 'files' and split_part(name, '/', 1) = (select auth.uid())::text
         and (select public.is_allowed()))
  with check (bucket_id = 'files' and split_part(name, '/', 1) = (select auth.uid())::text
              and (select public.is_allowed()));

-- 2. Заметки (док 02, раздел 6).
create type public.note_status as enum ('new', 'processed');

create table public.notes (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  text            text,
  attachment_path text,
  status          public.note_status not null default 'new',
  linked_entry_id uuid references public.entries (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint notes_has_content check (nullif(btrim(text), '') is not null or attachment_path is not null),
  constraint notes_processed_linked check ((status = 'processed') = (linked_entry_id is not null))
);

create index notes_user_status on public.notes (user_id, status);
create index notes_linked_entry on public.notes (linked_entry_id);

alter table public.entries
  add constraint entries_source_note_fk foreign key (source_note_id) references public.notes (id) on delete set null;
create index entries_source_note on public.entries (source_note_id);

-- 3. Вложения записей (док 02, раздел 7).
create table public.attachments (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  entry_id   uuid not null references public.entries (id) on delete cascade,
  file_path  text not null,
  file_name  text,
  kind       text not null default 'receipt' check (kind in ('receipt', 'screenshot', 'invoice')),
  created_at timestamptz not null default now(),
  unique (entry_id, file_path)
);

create index attachments_entry on public.attachments (entry_id);
create index attachments_user_path on public.attachments (user_id, file_path);

-- С клиента только чтение; пишут RPC ниже (проверка пути файла и своей записи).
select public.apply_user_rls('public.notes');
select public.apply_user_rls('public.attachments');
revoke all on public.notes, public.attachments from authenticated;
grant select on public.notes, public.attachments to authenticated;

-- 4. Проверки.

-- Свой загруженный файл: путь в своей папке и объект есть в бакете, иначе file_not_found.
create function engine.own_file(p_user uuid, p_path text) returns text
language plpgsql stable as $$
begin
  if p_path is null or split_part(p_path, '/', 1) <> p_user::text
     or not exists (select 1 from storage.objects where bucket_id = 'files' and name = p_path) then
    perform engine.raise_error('file_not_found', jsonb_build_object('path', p_path));
  end if;
  return p_path;
end $$;

-- Своя заметка по id или note_not_found.
create function engine.own_note(p_user uuid, p_note uuid) returns public.notes
language plpgsql stable as $$
declare
  n public.notes;
begin
  select * into n from public.notes where id = p_note and user_id = p_user;
  if not found then
    perform engine.raise_error('note_not_found', jsonb_build_object('note_id', p_note));
  end if;
  return n;
end $$;

-- Пути из списка, на которые после удаления строк не ссылается ни заметка, ни вложение:
-- их клиент удаляет из Storage.
create function engine.unreferenced_files(p_user uuid, p_paths text[]) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(distinct p order by p), '[]'::jsonb)
  from unnest(p_paths) as p
  where p is not null
    and not exists (select 1 from public.notes where user_id = p_user and attachment_path = p)
    and not exists (select 1 from public.attachments where user_id = p_user and file_path = p)
$$;

-- 5. Заметки: создать, удалить.

-- Заметка текстом и/или скрином (файл уже загружен в свою папку). Пустая = note_empty.
create function public.create_note(p_text text, p_attachment_path text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_id   uuid;
  v_text text := nullif(btrim(p_text), '');
begin
  perform public.assert_allowed();
  if v_text is null and p_attachment_path is null then
    perform engine.raise_error('note_empty');
  end if;
  if p_attachment_path is not null then
    perform engine.own_file(auth.uid(), p_attachment_path);
  end if;
  insert into public.notes (user_id, text, attachment_path)
  values (auth.uid(), v_text, p_attachment_path)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'note_id', v_id);
end $$;

-- Удалить заметку (новую или разобранную). Запись, сделанная из неё, остаётся без ссылки
-- (source_note_id on delete set null). Ответ: { ok, removed_files } (скрин, если он больше
-- никому не нужен: скрин разобранной заметки остаётся вложением записи).
create function public.delete_note(p_note_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n public.notes;
begin
  perform public.assert_allowed();
  n := engine.own_note(auth.uid(), p_note_id);
  delete from public.notes where id = n.id;
  return jsonb_build_object('ok', true,
    'removed_files', engine.unreferenced_files(n.user_id, array[n.attachment_path]));
end $$;

-- Удалили запись, сделанную из заметки: заметка снова новая и возвращается в инбокс (её
-- содержимое больше нигде не учтено). Срабатывает до каскада FK linked_entry_id.
create function engine.note_entry_deleted() returns trigger
language plpgsql as $$
begin
  update public.notes set status = 'new', linked_entry_id = null, updated_at = now()
  where linked_entry_id = old.id;
  return old;
end $$;

create trigger entries_note_back_to_new before delete on public.entries
for each row execute function engine.note_entry_deleted();

-- 6. Ссылку записи на заметку ставит только разбор (convert_note_to_entry): create_entry
-- присланный source_note_id отбрасывает, правка сохраняет прежний. Иначе тело как в тикете 15.
create or replace function public.create_entry(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.entries;
begin
  perform public.assert_allowed();
  e := engine.entry_from_payload(auth.uid(), p_payload);
  e.id := gen_random_uuid();
  e.created_at := now();
  e.source_note_id := null;
  e := engine.check_entry(e);
  perform engine.require_category(e);
  e := engine.insert_entry(e);
  return engine.saved(e, true);
end $$;

create or replace function engine.update_entry(prior public.entries, p_payload jsonb, p_category_required boolean)
returns jsonb
language plpgsql as $$
declare
  e public.entries;
begin
  e := engine.entry_from_payload(prior.user_id, p_payload);
  e.id := prior.id;
  e.created_at := prior.created_at;
  e.seq := prior.seq;
  e.source_note_id := prior.source_note_id;
  if e.type is distinct from 'expense' then
    perform engine.assert_no_refunds(prior);
  end if;
  e := engine.check_entry(e);
  if p_category_required then
    perform engine.require_category(e);
  end if;
  e := engine.replace_entry(e);
  if e.type = 'expense' then
    perform engine.sync_refunds(e);
  end if;
  return engine.saved(e, true);
end $$;

-- «Сделать запись» из заметки (док 05): запись любого типа ровно как create_entry (та же проверка
-- полной формы, пересчёт, предупреждения), затем связь в обе стороны, заметка разобрана; скрин
-- заметки становится вложением записи («screenshot»). Всё одной транзакцией: ошибка проверки
-- или пересчёта откатывает и запись, и разбор. Ответ create_entry плюс note_id.
create function public.convert_note_to_entry(p_note_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n       public.notes;
  v_saved jsonb;
  v_entry uuid;
begin
  perform public.assert_allowed();
  n := engine.own_note(auth.uid(), p_note_id);
  if n.status <> 'new' then
    perform engine.raise_error('note_already_processed',
      jsonb_build_object('note_id', n.id, 'entry_id', n.linked_entry_id));
  end if;
  v_saved := public.create_entry(p_payload);
  v_entry := (v_saved ->> 'entry_id')::uuid;
  update public.entries set source_note_id = n.id where id = v_entry;
  update public.notes set status = 'processed', linked_entry_id = v_entry, updated_at = now()
  where id = n.id;
  if n.attachment_path is not null then
    insert into public.attachments (user_id, entry_id, file_path, kind)
    values (n.user_id, v_entry, n.attachment_path, 'screenshot');
  end if;
  return v_saved || jsonb_build_object('note_id', n.id);
end $$;

-- 7. Вложения записи: файл уже загружен в свою папку; запись своя, любого статуса.
create function public.add_attachment(p_entry_id uuid, p_file_path text, p_kind text default 'receipt',
                                      p_file_name text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e    public.entries;
  v_id uuid;
begin
  perform public.assert_allowed();
  e := engine.own_entry(auth.uid(), p_entry_id);
  if coalesce(p_kind, '') not in ('receipt', 'screenshot', 'invoice') then
    perform engine.raise_error('field_invalid', '{"field": "kind"}');
  end if;
  perform engine.own_file(e.user_id, p_file_path);
  insert into public.attachments (user_id, entry_id, file_path, file_name, kind)
  values (e.user_id, e.id, p_file_path, nullif(btrim(p_file_name), ''), p_kind)
  on conflict (entry_id, file_path) do update set file_name = excluded.file_name, kind = excluded.kind
  returning id into v_id;
  return jsonb_build_object('ok', true, 'attachment_id', v_id);
end $$;

-- Открепить файл: { ok, removed_files }.
create function public.delete_attachment(p_attachment_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.attachments;
begin
  perform public.assert_allowed();
  delete from public.attachments where id = p_attachment_id and user_id = auth.uid()
  returning * into a;
  if not found then
    perform engine.raise_error('attachment_not_found', jsonb_build_object('attachment_id', p_attachment_id));
  end if;
  return jsonb_build_object('ok', true, 'removed_files', engine.unreferenced_files(a.user_id, array[a.file_path]));
end $$;

-- Удаление записи (тело тикета 13): вложения уходят каскадом, их файлы, которые больше никому не
-- нужны, в removed_files для клиента. Ответ: { ok, warnings, removed_files }.
create or replace function public.delete_entry(p_entry_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e       public.entries;
  v_paths text[];
begin
  perform public.assert_allowed();
  e := engine.own_entry(auth.uid(), p_entry_id);
  perform engine.assert_no_refunds(e);
  select coalesce(array_agg(file_path), '{}') into v_paths from public.attachments where entry_id = e.id;
  delete from public.entries where id = e.id;
  return jsonb_build_object('ok', true) || engine.recompute(e.user_id)
      || jsonb_build_object('removed_files', engine.unreferenced_files(e.user_id, v_paths));
end $$;

-- Страховка для Storage: свои файлы, на которые не ссылается ни заметка, ни вложение, старше
-- суток (свежие могут ждать своей заметки или вложения). Клиент удаляет их через Storage API.
create view public.v_orphan_files with (security_invoker = true) as
select o.name, o.created_at
from storage.objects o
where o.bucket_id = 'files'
  and split_part(o.name, '/', 1) = (select auth.uid())::text
  and o.created_at < now() - interval '1 day'
  and not exists (select 1 from public.notes n where n.user_id = (select auth.uid()) and n.attachment_path = o.name)
  and not exists (select 1 from public.attachments a where a.user_id = (select auth.uid()) and a.file_path = o.name);

revoke all on public.v_orphan_files from anon, authenticated;
grant select on public.v_orphan_files to authenticated;

-- 8. Инбокс (точка расширения тикета 15): новые заметки веткой union all, колонки заметки в
-- конце. Ветки записей без изменений. У заметки нет записи, суммы и счёта.
create or replace view public.v_inbox with (security_invoker = true) as
select case when e.status = 'draft' then 'draft' else 'no_category' end as kind,
       e.id as entry_id, e.occurred_on, e.amount_minor, e.currency, e.account_id, a.name as account_name,
       e.purpose, e.title, e.comment, e.source_pending, e.created_at,
       null::uuid as note_id, null::text as note_text, null::text as note_attachment_path
from public.entries e
left join public.accounts a on a.id = e.account_id
where e.user_id = (select auth.uid())
  and (e.status = 'draft' or (e.type = 'expense' and e.category_id is null))
union all
select 'note', null, null, null, null, null, null,
       null, null, null, false, n.created_at,
       n.id, n.text, n.attachment_path
from public.notes n
where n.user_id = (select auth.uid()) and n.status = 'new';

-- 9. Доступ к функциям.
revoke all on function public.create_note(text, text) from public, anon;
grant execute on function public.create_note(text, text) to authenticated;
revoke all on function public.convert_note_to_entry(uuid, jsonb), public.delete_note(uuid),
  public.add_attachment(uuid, text, text, text), public.delete_attachment(uuid) from public, anon;
grant execute on function public.delete_note(uuid), public.add_attachment(uuid, text, text, text),
  public.delete_attachment(uuid) to authenticated;
grant execute on function public.convert_note_to_entry(uuid, jsonb) to authenticated;

revoke all on all functions in schema engine from public;
