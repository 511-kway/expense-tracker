-- Импорт (док 04, раздел 8; док 05; ADR-0004; тикет 18). Edge Function `import_parse` превращает
-- файл в строки импорта (названия счетов и категорий, суммы модулем целыми тиынами строкой, знак
-- корректировки отдельно; правило знака и схема в supabase/functions/_shared/schema.ts). Здесь:
--   import_preview(rows) — партия со строками, проверка каждой строки теми же функциями, что
--     create_entry (entry_from_payload → check_entry → require_category → insert_entry), один
--     пересчёт, возможные дубли по отпечатку в окне ±3 дня; всё откатывается, остаётся партия;
--   import_commit(batch) — то же самое всерьёз: все строки учтёнными одной транзакцией, пересчёт
--     один раз в конце, повторы по external_id пропускаются. Любая ошибка откатывает все записи,
--     партия при этом остаётся «неудачной» с отчётом по строкам (откат в подтранзакции).

-- 1. Партии импорта (док 02, раздел 9).
create table public.import_batches (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users on delete cascade,
  filename     text,
  format       text check (format in ('csv', 'xlsx', 'json')),
  status       text not null default 'preview' check (status in ('preview', 'committed', 'failed')),
  rows         jsonb not null,                -- строки импорта от import_parse, как пришли
  report       jsonb not null default '[]',   -- отчёт по строкам последней проверки
  rows_total   int not null,
  rows_created int not null default 0,
  rows_skipped int not null default 0,        -- уже импортированные (external_id) и оставленные владельцем
  created_at   timestamptz not null default now(),
  committed_at timestamptz
);
create index import_batches_user on public.import_batches (user_id, created_at desc);

select public.apply_user_rls('public.import_batches');
-- С клиента только чтение: партии пишут import_preview и import_commit.
revoke all on public.import_batches from anon, authenticated;
grant select on public.import_batches to authenticated;

alter table public.entries
  add constraint entries_import_batch_fk foreign key (import_batch_id) references public.import_batches (id);
create index entries_import_batch on public.entries (import_batch_id) where import_batch_id is not null;
create index entries_user_external_id on public.entries (user_id, external_id) where external_id is not null;

-- 2. Строка импорта → payload create_entry.

-- Колонка файла для поля payload: отчёт говорит на языке файла (account, а не account_id).
create function engine.import_field(p_field text) returns text
language sql immutable as $$
  select case p_field
    when 'account_id'       then 'account'
    when 'to_account_id'    then 'to_account'
    when 'category_id'      then 'category'
    when 'amount_minor'     then 'amount'
    when 'fee_minor'        then 'fee'
    when 'amount_kzt_minor' then 'amount_kzt'
    when 'parent_entry_id'  then 'parent_external_id'
    else p_field
  end
$$;

-- Ошибка строки {code, field, details} из ошибки RPC: код в message, JSON в detail (док 05).
-- Поле берётся из details или по коду, чтобы экран мог подсветить колонку.
create function engine.import_error(p_code text, p_detail text) returns jsonb
language plpgsql immutable as $$
declare
  v_info jsonb;
begin
  begin
    v_info := coalesce(nullif(p_detail, '')::jsonb, '{}');
  exception when others then
    v_info := jsonb_build_object('message', p_detail);
  end;
  if jsonb_typeof(v_info) <> 'object' then
    v_info := '{}';
  end if;
  return jsonb_build_object(
    'code', p_code,
    'field', engine.import_field(coalesce(v_info ->> 'field', case p_code
      when 'amount_not_positive'          then 'amount'
      when 'fee_too_big'                  then 'fee'
      when 'same_account_transfer'        then 'to_account'
      when 'cross_currency_transfer'      then 'to_account'
      when 'entry_before_start'           then 'occurred_on'
      when 'refund_before_expense'        then 'occurred_on'
      when 'account_currency_mismatch'    then 'currency'
      when 'foreign_amount_not_supported' then 'currency'
      when 'currency_invalid'             then 'currency'
      when 'fx_rate_missing'              then 'rate'
      when 'source_required'              then 'source'
    end)),
    'details', v_info - 'field');
end $$;

-- Сумма строки (целые тиыны строкой) → целое JSON для payload.
create function engine.import_minor(r jsonb, p_key text) returns jsonb
language plpgsql immutable as $$
begin
  if r ->> p_key is null then
    return null;
  end if;
  if r ->> p_key !~ '^[0-9]{1,18}$' then
    perform engine.raise_error('field_invalid', jsonb_build_object('field', p_key));
  end if;
  return to_jsonb((r ->> p_key)::bigint);
end $$;

-- Счёт по точному названию (названия счетов уникальны у пользователя, тикет 06).
create function engine.import_account(p_user uuid, p_name text, p_field text) returns uuid
language plpgsql stable as $$
declare
  v_id uuid;
begin
  if p_name is null then
    return null;
  end if;
  select id into v_id from public.accounts where user_id = p_user and name = p_name;
  if v_id is null then
    perform engine.raise_error('account_not_found', jsonb_build_object('field', p_field, 'name', p_name));
  end if;
  return v_id;
end $$;

-- Категория по точному названию.
create function engine.import_category(p_user uuid, p_name text) returns uuid
language plpgsql stable as $$
declare
  v_id uuid;
begin
  if p_name is null then
    return null;
  end if;
  select id into v_id from public.categories where user_id = p_user and name = p_name;
  if v_id is null then
    perform engine.raise_error('category_not_found', jsonb_build_object('field', 'category', 'name', p_name));
  end if;
  return v_id;
end $$;

-- Запись по внешнему идентификатору: свой external_id или id записи (так их пишет экспорт).
create function engine.entry_by_external_id(p_user uuid, p_external_id text) returns uuid
language plpgsql stable as $$
declare
  v_id uuid;
begin
  select id into v_id from public.entries
  where user_id = p_user and external_id = p_external_id
  order by (status = 'done') desc, seq
  limit 1;
  if v_id is null and p_external_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select id into v_id from public.entries where user_id = p_user and id = p_external_id::uuid;
  end if;
  return v_id;
end $$;

create function engine.import_payload(p_user uuid, r jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_parent uuid;
begin
  if r ->> 'parent_external_id' is not null then
    v_parent := engine.entry_by_external_id(p_user, r ->> 'parent_external_id');
    if v_parent is null then
      perform engine.raise_error('entry_not_found', jsonb_build_object(
        'field', 'parent_external_id', 'parent_external_id', r ->> 'parent_external_id'));
    end if;
  end if;
  -- Импорт не видит аванс, который принесут строки того же файла (журнал пересчитывается один раз
  -- в конце), поэтому источник личной траты в файле обязателен, а не выводится по авансу.
  if r ->> 'type' = 'expense' and r ->> 'purpose' = 'personal' and r ->> 'source' is null then
    perform engine.raise_error('source_required', '{"field": "source"}');
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'type', r -> 'type', 'occurred_on', r -> 'occurred_on',
    'amount_minor', engine.import_minor(r, 'amount_minor'), 'currency', r -> 'currency',
    'amount_kzt_minor', engine.import_minor(r, 'amount_kzt_minor'),
    'rate', r -> 'rate', 'rate_source', r -> 'rate_source',
    'account_id', engine.import_account(p_user, r ->> 'account', 'account'),
    'to_account_id', engine.import_account(p_user, r ->> 'to_account', 'to_account'),
    'category_id', engine.import_category(p_user, r ->> 'category'),
    'purpose', r -> 'purpose', 'source', r -> 'source', 'transfer_purpose', r -> 'transfer_purpose',
    'fee_minor', engine.import_minor(r, 'fee_minor'), 'fee_payer', r -> 'fee_payer',
    'settlement_direction', r -> 'settlement_direction',
    'adjustment_target', r -> 'adjustment_target', 'adjustment_mode', r -> 'adjustment_mode',
    'adjustment_sign', r -> 'adjustment_sign', 'adjustment_affects_advance', r -> 'adjustment_affects_advance',
    'in_analytics', r -> 'in_analytics', 'comment', r -> 'comment', 'title', r -> 'title',
    'external_id', r -> 'external_id', 'parent_entry_id', to_jsonb(v_parent)));
end $$;

-- Возможные дубли записи n (док 03, раздел 6): учтённые записи с тем же отпечатком в окне ±3 дня.
-- Отпечаток включает дату, поэтому сравнивается с отпечатками n, сдвинутой на каждый день окна.
-- Из своей партии считаются только строки выше по файлу (дубль внутри файла виден у второй).
create function engine.import_duplicates(n public.entries) returns setof public.entries
language plpgsql stable as $$
declare
  m     public.entries := n;
  v_fps text[] := '{}';
  k     int;
begin
  for k in -3..3 loop
    m.occurred_on := n.occurred_on + k;
    v_fps := v_fps || engine.fingerprint(m);
  end loop;
  return query
    select d.* from public.entries d
    where d.user_id = n.user_id and d.fingerprint = any(v_fps) and d.id <> n.id and d.status = 'done'
      and (d.import_batch_id is distinct from n.import_batch_id or d.seq < n.seq)
    order by d.occurred_on, d.seq;
end $$;

-- 3. Прогон партии: создаёт строки и пересчитывает журнал, ничего не откатывает (это решает
-- вызывающий). Ответ: {rows: [{line, status, errors, duplicates, entry_id}], warnings, счётчики}.
-- status строки: create (будет создана), skip (уже импортирована: external_id есть в базе),
-- excluded (владелец оставил её при подтверждении), error. Ошибка одной строки не мешает
-- проверить остальные: каждая строка в своей подтранзакции.
create function engine.import_run(b public.import_batches, p_exclude int[]) returns jsonb
language plpgsql as $$
declare
  r        jsonb;
  v_line   int;
  v_ext    text;
  v_status text;
  v_errors jsonb;
  v_dups   jsonb;
  v_item   jsonb;
  v_items  jsonb := '[]';
  v_lines  jsonb := '{}';   -- id созданной записи → номер строки
  v_seen   jsonb := '{}';   -- external_id → номер строки в этом файле
  v_found  uuid;
  v_warn   jsonb := '[]';
  v_err    jsonb;
  v_idx    int;
  e        public.entries;
  d        public.entries;
  v_code   text;
  v_detail text;
  v_created int := 0;
  v_skipped int := 0;
begin
  for r in select value from jsonb_array_elements(b.rows) loop
    v_line := (r ->> 'line')::int;
    v_ext := nullif(btrim(r ->> 'external_id'), '');
    v_status := 'create';
    v_errors := coalesce(r -> 'errors', '[]');
    v_dups := '[]';
    v_found := null;
    if jsonb_typeof(v_errors) <> 'array' then
      v_errors := '[]';
    end if;

    if v_ext is not null and v_seen ? v_ext then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('code', 'duplicate_external_id',
        'field', 'external_id', 'details', jsonb_build_object('line', v_seen -> v_ext)));
    elsif v_ext is not null then
      v_seen := v_seen || jsonb_build_object(v_ext, v_line);
      v_found := engine.entry_by_external_id(b.user_id, v_ext);
    end if;

    if v_found is not null then
      v_status := 'skip';
      v_skipped := v_skipped + 1;
    elsif v_line = any(p_exclude) then
      v_status := 'excluded';
      v_skipped := v_skipped + 1;
    elsif jsonb_array_length(v_errors) = 0 then
      begin
        e := engine.entry_from_payload(b.user_id, engine.import_payload(b.user_id, r));
        e.id := gen_random_uuid();
        e.created_at := now();
        e := engine.check_entry(e);
        perform engine.require_category(e);
        e.import_batch_id := b.id;
        e := engine.insert_entry(e);
        v_lines := v_lines || jsonb_build_object(e.id, v_line);
        v_created := v_created + 1;
        for d in select * from engine.import_duplicates(e) loop
          v_dups := v_dups || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
            'entry_id', d.id, 'occurred_on', d.occurred_on, 'title', d.title, 'amount_minor', d.amount_minor,
            'line', v_lines -> d.id::text)));
        end loop;
      exception when others then
        get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
        v_errors := v_errors || jsonb_build_array(engine.import_error(v_code, v_detail));
      end;
    end if;

    if jsonb_array_length(v_errors) > 0 then
      v_status := 'error';
    end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'line', v_line, 'status', v_status, 'errors', v_errors, 'duplicates', v_dups,
      'entry_id', coalesce(v_found, case when v_status = 'create' then e.id end),
      'type', r -> 'type', 'occurred_on', r -> 'occurred_on', 'account', r -> 'account',
      'to_account', r -> 'to_account', 'category', r -> 'category', 'title', r -> 'title',
      'amount_minor', r -> 'amount_minor', 'currency', r -> 'currency', 'adjustment_sign', r -> 'adjustment_sign',
      'external_id', r -> 'external_id'));
  end loop;

  -- Один пересчёт на партию. Нарушение правила на дату (ADR-0006) приходит с id записи: это
  -- ошибка её строки. Предупреждения (остаток в минусе) тоже с номером строки.
  if v_created > 0 then
    begin
      v_warn := coalesce(engine.recompute(b.user_id) -> 'warnings', '[]');
    exception when others then
      get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
      v_err := engine.import_error(v_code, v_detail);
      v_line := (v_lines ->> (v_err -> 'details' ->> 'entry_id'))::int;
      select ord - 1 into v_idx from jsonb_array_elements(v_items) with ordinality x(item, ord)
      where (item ->> 'line')::int = v_line;
      if v_idx is null then
        -- Сломалась запись не из файла (её подвинули строки файла): ошибка партии на первой строке.
        v_idx := 0;
      end if;
      v_item := v_items -> v_idx;
      v_items := jsonb_set(v_items, array[v_idx::text], v_item
        || jsonb_build_object('status', 'error', 'errors', (v_item -> 'errors') || jsonb_build_array(v_err)));
    end;
  end if;
  select coalesce(jsonb_agg(w || jsonb_strip_nulls(jsonb_build_object('line', v_lines -> (w ->> 'entry_id')))), '[]')
    into v_warn from jsonb_array_elements(v_warn) w;

  return jsonb_build_object(
    'rows', v_items,
    'warnings', v_warn,
    'rows_total', jsonb_array_length(b.rows),
    'rows_create', (select count(*) from jsonb_array_elements(v_items) i where i ->> 'status' = 'create'),
    'rows_skip', v_skipped,
    'rows_error', (select count(*) from jsonb_array_elements(v_items) i where i ->> 'status' = 'error'),
    'rows_duplicate', (select count(*) from jsonb_array_elements(v_items) i
                       where jsonb_array_length(i -> 'duplicates') > 0));
end $$;

-- 4. RPC (док 05).

-- Своя партия по id или import_batch_not_found (чужую не видно так же, как несуществующую).
create function engine.own_batch(p_user uuid, p_batch uuid) returns public.import_batches
language plpgsql as $$
declare
  b public.import_batches;
begin
  select * into b from public.import_batches where id = p_batch and user_id = p_user for update;
  if not found then
    perform engine.raise_error('import_batch_not_found', jsonb_build_object('batch_id', p_batch));
  end if;
  return b;
end $$;

/* import_preview(rows, filename, format) → {batch_id, status, rows, warnings, rows_*}. Ничего не
   создаёт: прогон партии откатывается, остаётся партия «предпросмотр» со строками и отчётом. */
create function public.import_preview(p_rows jsonb, p_filename text default null, p_format text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  b        public.import_batches;
  v_report jsonb;
begin
  perform public.assert_allowed();
  if p_rows is null or jsonb_typeof(p_rows) <> 'array'
     or exists (select 1 from jsonb_array_elements(p_rows) r
                where jsonb_typeof(r) <> 'object' or jsonb_typeof(r -> 'line') <> 'number') then
    perform engine.raise_error('field_invalid', '{"field": "rows"}');
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    perform engine.raise_error('too_many_rows', '{"limit": 5000}');
  end if;
  if p_format is not null and p_format not in ('csv', 'xlsx', 'json') then
    perform engine.raise_error('field_invalid', '{"field": "format"}');
  end if;

  insert into public.import_batches (user_id, filename, format, rows, rows_total)
  values (auth.uid(), p_filename, p_format, p_rows, jsonb_array_length(p_rows))
  returning * into b;

  begin
    v_report := engine.import_run(b, '{}');
    raise exception using errcode = 'IM001', message = 'import_preview_rollback';
  exception when sqlstate 'IM001' then
    null;
  end;

  update public.import_batches set report = v_report -> 'rows' where id = b.id;
  return jsonb_build_object('batch_id', b.id, 'status', 'preview') || v_report;
end $$;

/* import_commit(batch_id, exclude_lines) → {ok, batch_id, status, created, skipped, rows, warnings}.
   Все строки учтёнными записями одной транзакцией, пересчёт один раз в конце (ADR-0004). Строки
   с external_id, который уже есть в базе, пропускаются; строки из p_exclude_lines владелец
   решил не создавать (возможные дубли). Любая ошибка: ни одной записи, партия «неудачна», в ответе
   и в партии отчёт по строкам; функция при этом не падает, иначе пометка откатилась бы вместе
   с записями. */
create function public.import_commit(p_batch_id uuid, p_exclude_lines int[] default '{}')
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  b        public.import_batches;
  v_report jsonb;
  v_failed boolean := false;
  v_code   text;
  v_detail text;
begin
  perform public.assert_allowed();
  b := engine.own_batch(auth.uid(), p_batch_id);
  if b.status = 'committed' then
    perform engine.raise_error('import_batch_committed', jsonb_build_object('batch_id', b.id));
  end if;

  begin
    v_report := engine.import_run(b, coalesce(p_exclude_lines, '{}'));
    if (v_report ->> 'rows_error')::int > 0 then
      raise exception using errcode = 'IM002', message = 'import_commit_rollback';
    end if;
  exception
    when sqlstate 'IM002' then
      v_failed := true;
    when others then
      -- Сбой вне строк (не должен случаться): тоже откат и «неудачна», код в отчёте партии.
      get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
      v_failed := true;
      v_report := jsonb_build_object('rows', jsonb_build_array(jsonb_build_object(
        'line', null, 'status', 'error', 'errors', jsonb_build_array(engine.import_error(v_code, v_detail)),
        'duplicates', '[]'::jsonb)), 'warnings', '[]'::jsonb, 'rows_error', 1, 'rows_skip', 0, 'rows_create', 0);
  end;

  if v_failed then
    update public.import_batches
    set status = 'failed', report = v_report -> 'rows', rows_created = 0, rows_skipped = 0
    where id = b.id;
    return jsonb_build_object('ok', false, 'batch_id', b.id, 'status', 'failed', 'created', 0, 'skipped', 0)
        || v_report;
  end if;

  update public.import_batches
  set status = 'committed', report = v_report -> 'rows', committed_at = now(),
      rows_created = (v_report ->> 'rows_create')::int, rows_skipped = (v_report ->> 'rows_skip')::int
  where id = b.id;
  return jsonb_build_object('ok', true, 'batch_id', b.id, 'status', 'committed',
           'created', (v_report ->> 'rows_create')::int, 'skipped', (v_report ->> 'rows_skip')::int)
      || v_report;
end $$;

revoke all on function public.import_preview(jsonb, text, text), public.import_commit(uuid, int[]) from public, anon;
grant execute on function public.import_preview(jsonb, text, text), public.import_commit(uuid, int[]) to authenticated;
revoke all on all functions in schema engine from public;
