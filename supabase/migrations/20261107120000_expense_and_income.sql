-- Трата и поступление (тикет 07): категории, общие RPC записей create_entry / update_entry /
-- delete_entry, движок для expense и income, предупреждения пересчёта (остаток в минусе)
-- и мягкое предупреждение о дубле. Док 02 (разделы 3, 4), док 03 (4.1, 4.2, 6, 8), док 05.

-- 1. Категории (док 02, раздел 3). Название уникально у пользователя без учёта регистра.

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (name = btrim(name) and name <> ''),
  icon        text,
  is_archived boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint categories_user_id_id unique (user_id, id)  -- для составного FK из записей
);

create unique index categories_user_name on public.categories (user_id, lower(name));

-- Запись ссылается только на свою категорию; категорию с записями не удалить (только архив).
alter table public.entries
  add constraint entries_category_fk foreign key (user_id, category_id)
    references public.categories (user_id, id) on delete restrict;
create index entries_category on public.entries (user_id, category_id) where category_id is not null;

-- С клиента категории только читаются: создание, переименование и архив через RPC.
select public.apply_user_rls('public.categories');
revoke all on public.categories from authenticated;
grant select on public.categories to authenticated;

create function engine.own_category(p_user uuid, p_category uuid) returns public.categories
language plpgsql stable as $$
declare
  c public.categories;
begin
  select * into c from public.categories where id = p_category and user_id = p_user;
  if not found then
    perform engine.raise_error('category_not_found', jsonb_build_object('category_id', p_category));
  end if;
  return c;
end $$;

create function engine.check_category_name(p_name text) returns void
language plpgsql immutable as $$
begin
  if p_name is null or btrim(p_name) = '' then
    perform engine.raise_error('missing_required', '{"field": "name"}');
  end if;
end $$;

create function public.create_category(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  perform public.assert_allowed();
  perform engine.check_category_name(p_name);
  insert into public.categories (user_id, name) values (auth.uid(), btrim(p_name))
  on conflict (user_id, lower(name)) do nothing
  returning id into v_id;
  if v_id is null then
    perform engine.raise_error('category_name_taken', jsonb_build_object('name', btrim(p_name)));
  end if;
  return jsonb_build_object('ok', true, 'category_id', v_id);
end $$;

create function public.rename_category(p_category_id uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c public.categories;
begin
  perform public.assert_allowed();
  c := engine.own_category(auth.uid(), p_category_id);
  perform engine.check_category_name(p_name);
  update public.categories set name = btrim(p_name), updated_at = now() where id = c.id;
  return jsonb_build_object('ok', true);
exception when unique_violation then
  perform engine.raise_error('category_name_taken', jsonb_build_object('name', btrim(p_name)));
end $$;

create function public.archive_category(p_category_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c public.categories;
begin
  perform public.assert_allowed();
  c := engine.own_category(auth.uid(), p_category_id);
  update public.categories set is_archived = true, updated_at = now() where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

create function public.unarchive_category(p_category_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c public.categories;
begin
  perform public.assert_allowed();
  c := engine.own_category(auth.uid(), p_category_id);
  update public.categories set is_archived = false, updated_at = now() where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.create_category(text), public.rename_category(uuid, text),
  public.archive_category(uuid), public.unarchive_category(uuid) from public, anon;
grant execute on function public.create_category(text), public.rename_category(uuid, text),
  public.archive_category(uuid), public.unarchive_category(uuid) to authenticated;

-- 2. Payload записи (док 05, create_entry): JSON со всеми полями контракта, суммы только
-- целыми минимальными единицами. Читается в строку entries без проверок по типу: их делает
-- engine.check_entry. Неверный тип значения даёт field_invalid с именем поля.

-- Значение поля payload текстом после проверки, что оно приводится к p_type; null, если поля нет.
create function engine.payload_value(p jsonb, p_key text, p_type regtype) returns text
language plpgsql stable as $$
declare
  v_kind text := jsonb_typeof(p -> p_key);
  v_ok   boolean := true;
begin
  if v_kind is null or v_kind = 'null' then
    return null;
  end if;
  if p_type in ('bigint'::regtype, 'smallint'::regtype) then
    -- Деньги и знаки только целым числом JSON: не строкой и не дробью.
    v_ok := v_kind = 'number' and (p ->> p_key)::numeric = trunc((p ->> p_key)::numeric);
  elsif p_type = 'numeric'::regtype then
    v_ok := v_kind = 'number';
  elsif p_type = 'boolean'::regtype then
    v_ok := v_kind = 'boolean';
  else
    v_ok := v_kind = 'string';
  end if;
  if v_ok then
    begin
      execute format('select %L::%s', p ->> p_key, p_type);
    exception when others then
      v_ok := false;
    end;
  end if;
  if not v_ok then
    perform engine.raise_error('field_invalid', jsonb_build_object('field', p_key));
  end if;
  return p ->> p_key;
end $$;

create function engine.payload_text(p jsonb, p_key text) returns text
language sql stable as $$ select nullif(btrim(engine.payload_value(p, p_key, 'text')), '') $$;

-- Payload → строка записи пользователя. Служебные поля (id, seq, отпечаток, партия импорта)
-- из payload не берутся.
create function engine.entry_from_payload(p_user uuid, p jsonb) returns public.entries
language plpgsql stable as $$
declare
  e public.entries;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    perform engine.raise_error('field_invalid', '{"field": "payload"}');
  end if;
  e.user_id                    := p_user;
  e.type                       := engine.payload_value(p, 'type', 'public.entry_type');
  e.status                     := coalesce(engine.payload_value(p, 'status', 'public.entry_status'), 'done');
  e.occurred_on                := engine.payload_value(p, 'occurred_on', 'date');
  e.occurred_at                := engine.payload_value(p, 'occurred_at', 'timestamptz');
  e.amount_minor               := engine.payload_value(p, 'amount_minor', 'bigint');
  e.currency                   := engine.payload_value(p, 'currency', 'text');
  e.amount_kzt_minor           := engine.payload_value(p, 'amount_kzt_minor', 'bigint');
  e.rate                       := engine.payload_value(p, 'rate', 'numeric');
  e.rate_source                := engine.payload_value(p, 'rate_source', 'public.rate_source');
  e.account_id                 := engine.payload_value(p, 'account_id', 'uuid');
  e.to_account_id              := engine.payload_value(p, 'to_account_id', 'uuid');
  e.category_id                := engine.payload_value(p, 'category_id', 'uuid');
  e.purpose                    := engine.payload_value(p, 'purpose', 'public.purpose');
  e.source                     := engine.payload_value(p, 'source', 'public.money_source');
  e.transfer_purpose           := engine.payload_value(p, 'transfer_purpose', 'public.transfer_purpose');
  e.fee_minor                  := coalesce(engine.payload_value(p, 'fee_minor', 'bigint')::bigint, 0);
  e.fee_payer                  := engine.payload_value(p, 'fee_payer', 'public.fee_payer');
  e.settlement_direction       := engine.payload_value(p, 'settlement_direction', 'public.settlement_direction');
  e.adjustment_mode            := engine.payload_value(p, 'adjustment_mode', 'public.adjustment_mode');
  e.adjustment_sign            := engine.payload_value(p, 'adjustment_sign', 'smallint');
  e.adjustment_affects_advance := coalesce(engine.payload_value(p, 'adjustment_affects_advance', 'boolean')::boolean, false);
  e.adjustment_target          := engine.payload_value(p, 'adjustment_target', 'public.adjustment_target');
  e.in_analytics               := coalesce(engine.payload_value(p, 'in_analytics', 'boolean')::boolean, true);
  e.comment                    := engine.payload_text(p, 'comment');
  e.title                      := engine.payload_text(p, 'title');
  e.parent_entry_id            := engine.payload_value(p, 'parent_entry_id', 'uuid');
  e.source_note_id             := engine.payload_value(p, 'source_note_id', 'uuid');
  e.external_id                := engine.payload_text(p, 'external_id');
  return e;
end $$;

-- 3. Проверка записи перед сохранением (док 03, раздел 8). Одна точка разбора по типу:
-- engine.check_entry проверяет общие поля и зовёт engine.check_<тип>(n, e), который переносит
-- из сырой записи e в чистую n только поля своего типа (остальные остаются пустыми) и проверяет
-- их. Новый тип записи (тикеты 09–13) = функция engine.check_<тип> и ветка в check_entry.
-- У e уже стоят id, created_at и seq (для новой записи seq пуст): место в хронологии нужно
-- проверкам, которые смотрят на состояние «на момент записи».

-- Свой счёт записи: существует, у пользователя, дата записи не раньше даты старта счёта (ADR-0008).
create function engine.check_entry_account(e public.entries, p_account uuid, p_field text)
returns public.accounts
language plpgsql stable as $$
declare
  a public.accounts;
begin
  if p_account is null then
    perform engine.raise_error('missing_required', jsonb_build_object('field', p_field));
  end if;
  a := engine.own_account(e.user_id, p_account);
  if e.occurred_on < a.start_date then
    perform engine.raise_error('entry_before_start', jsonb_build_object(
      'occurred_on', e.occurred_on, 'account_id', a.id, 'start_date', a.start_date));
  end if;
  return a;
end $$;

-- Валюта записи на одном счёте. Пока только тенге на тенговом счёте: тенговый эквивалент,
-- курс и валютные счета приходят с тикетом 14. Тенговый эквивалент тенговой суммы равен ей.
create function engine.check_entry_currency(n public.entries, a public.accounts) returns public.entries
language plpgsql stable as $$
begin
  n.currency := coalesce(n.currency, a.currency);
  if n.currency <> 'KZT' or a.currency <> 'KZT' then
    perform engine.raise_error('foreign_amount_not_supported', jsonb_build_object(
      'currency', n.currency, 'account_currency', a.currency));
  end if;
  n.amount_kzt_minor := n.amount_minor;
  n.rate := null;
  n.rate_source := null;
  return n;
end $$;

-- Аванс счёта на момент записи e (перед ней в хронологии), по журналу последнего пересчёта.
-- Записи раньше e по порядку реплея от более поздних не зависят, поэтому журнал годится;
-- строки самой e (при правке) не считаются.
create function engine.advance_before(e public.entries, p_account uuid) returns bigint
language sql stable as $$
  select coalesce(sum(l.delta_minor), 0)::bigint
  from public.ledger_entries l
  join public.entries x on x.id = l.entry_id
  where l.user_id = e.user_id and l.account_id = p_account and l.target = 'card_advance'
    and x.id is distinct from e.id
    and (x.occurred_on, coalesce(x.occurred_at, 'infinity'), x.created_at, x.seq)
      < (e.occurred_on, coalesce(e.occurred_at, 'infinity'), e.created_at, coalesce(e.seq, 9223372036854775807))
$$;

-- Трата (док 03, 4.1; док 04, 4.2): счёт, назначение и категория обязательны. Источник
-- спрашивается только у личной траты со счёта, где на момент траты есть аванс; без аванса
-- он «свои». У рабочей источник не задаётся: сплит делает движок.
create function engine.check_expense(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a     public.accounts;
  v_adv bigint;
begin
  a := engine.check_entry_account(n, e.account_id, 'account_id');
  n.account_id := a.id;
  n := engine.check_entry_currency(n, a);
  if e.purpose is null then
    perform engine.raise_error('missing_required', '{"field": "purpose"}');
  end if;
  n.purpose := e.purpose;
  if e.category_id is null then
    perform engine.raise_error('missing_required', '{"field": "category_id"}');
  end if;
  n.category_id := (engine.own_category(n.user_id, e.category_id)).id;
  if n.purpose = 'personal' then
    n.source := e.source;
    if n.source is null then
      v_adv := engine.advance_before(n, a.id);
      if v_adv > 0 then
        perform engine.raise_error('source_required',
          jsonb_build_object('account_id', a.id, 'advance_minor', v_adv));
      end if;
      n.source := 'own';
    end if;
  end if;
  return n;
end $$;

-- Поступление своих денег (док 03, 4.2): счёт обязателен, категория по желанию.
create function engine.check_income(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a public.accounts;
begin
  a := engine.check_entry_account(n, e.account_id, 'account_id');
  n.account_id := a.id;
  n := engine.check_entry_currency(n, a);
  if e.category_id is not null then
    n.category_id := (engine.own_category(n.user_id, e.category_id)).id;
  end if;
  return n;
end $$;

-- Отпечаток для дедупа (док 03, раздел 6): дата, счёт, сумма, валюта, тип, заголовок или категория.
create function engine.fingerprint(e public.entries) returns text
language sql immutable as $$
  select md5(concat_ws('|', e.type, e.occurred_on, e.account_id, e.to_account_id, e.amount_minor, e.currency,
                       lower(coalesce(e.title, e.category_id::text, ''))))
$$;

create function engine.check_entry(e public.entries) returns public.entries
language plpgsql stable as $$
declare
  n       public.entries;
  v_start date;
begin
  if e.type is null then
    perform engine.raise_error('missing_required', '{"field": "type"}');
  end if;
  if e.status <> 'done' then
    -- Черновики появятся с быстрым вводом (тикет 15).
    perform engine.raise_error('entry_status_not_supported', jsonb_build_object('status', e.status));
  end if;
  if e.occurred_on is null then
    perform engine.raise_error('missing_required', '{"field": "occurred_on"}');
  end if;
  if e.amount_minor is null then
    perform engine.raise_error('missing_required', '{"field": "amount_minor"}');
  end if;
  if e.amount_minor <= 0 then
    perform engine.raise_error('amount_not_positive');
  end if;
  select accounting_start_date into v_start from public.user_settings where user_id = e.user_id;
  if v_start is null then
    perform engine.raise_error('start_not_set');
  end if;
  if e.occurred_on < v_start then
    perform engine.raise_error('entry_before_start', jsonb_build_object(
      'occurred_on', e.occurred_on, 'accounting_start_date', v_start));
  end if;

  -- Общие поля; поля типа переносит его проверка.
  n.id := e.id; n.user_id := e.user_id; n.created_at := e.created_at; n.seq := e.seq;
  n.type := e.type; n.status := e.status;
  n.occurred_on := e.occurred_on; n.occurred_at := e.occurred_at;
  n.amount_minor := e.amount_minor; n.currency := e.currency; n.amount_kzt_minor := e.amount_kzt_minor;
  n.rate := e.rate; n.rate_source := e.rate_source;
  n.source_pending := false; n.fee_minor := 0; n.adjustment_affects_advance := false;
  n.in_analytics := e.in_analytics;
  n.comment := e.comment; n.title := e.title;
  n.source_note_id := e.source_note_id; n.external_id := e.external_id;

  case e.type
    when 'expense' then n := engine.check_expense(n, e);
    when 'income'  then n := engine.check_income(n, e);
    else
      perform engine.raise_error('entry_type_not_supported', jsonb_build_object('type', e.type));
  end case;

  n.fingerprint := engine.fingerprint(n);
  return n;
end $$;

-- 4. Сохранение: единственные места, где RPC пишут строку записи (полный набор полей).

create function engine.insert_entry(n public.entries) returns public.entries
language plpgsql as $$
begin
  insert into public.entries (
    user_id, type, status, occurred_on, occurred_at, amount_minor, currency, amount_kzt_minor, rate,
    rate_source, account_id, to_account_id, category_id, purpose, source, source_pending, transfer_purpose,
    fee_minor, fee_payer, settlement_direction, adjustment_mode, adjustment_sign, adjustment_affects_advance,
    adjustment_target, in_analytics, comment, title, parent_entry_id, source_note_id, fingerprint,
    external_id, import_batch_id, created_at)
  values (
    n.user_id, n.type, n.status, n.occurred_on, n.occurred_at, n.amount_minor, n.currency, n.amount_kzt_minor,
    n.rate, n.rate_source, n.account_id, n.to_account_id, n.category_id, n.purpose, n.source, n.source_pending,
    n.transfer_purpose, n.fee_minor, n.fee_payer, n.settlement_direction, n.adjustment_mode, n.adjustment_sign,
    n.adjustment_affects_advance, n.adjustment_target, n.in_analytics, n.comment, n.title, n.parent_entry_id,
    n.source_note_id, n.fingerprint, n.external_id, n.import_batch_id, n.created_at)
  returning * into n;
  return n;
end $$;

-- Правка = полная замена полей (док 05); id, номер вставки и время создания остаются,
-- поэтому место записи среди записей того же дня не прыгает.
create function engine.replace_entry(n public.entries) returns public.entries
language plpgsql as $$
begin
  update public.entries set
    type = n.type, status = n.status, occurred_on = n.occurred_on, occurred_at = n.occurred_at,
    amount_minor = n.amount_minor, currency = n.currency, amount_kzt_minor = n.amount_kzt_minor,
    rate = n.rate, rate_source = n.rate_source, account_id = n.account_id, to_account_id = n.to_account_id,
    category_id = n.category_id, purpose = n.purpose, source = n.source, source_pending = n.source_pending,
    transfer_purpose = n.transfer_purpose, fee_minor = n.fee_minor, fee_payer = n.fee_payer,
    settlement_direction = n.settlement_direction, adjustment_mode = n.adjustment_mode,
    adjustment_sign = n.adjustment_sign, adjustment_affects_advance = n.adjustment_affects_advance,
    adjustment_target = n.adjustment_target, in_analytics = n.in_analytics, comment = n.comment,
    title = n.title, parent_entry_id = n.parent_entry_id, source_note_id = n.source_note_id,
    fingerprint = n.fingerprint, external_id = n.external_id, updated_at = now()
  where id = n.id
  returning * into n;
  return n;
end $$;

-- Своя запись по id или entry_not_found (чужую не видно так же, как несуществующую).
create function engine.own_entry(p_user uuid, p_entry uuid) returns public.entries
language plpgsql stable as $$
declare
  e public.entries;
begin
  select * into e from public.entries where id = p_entry and user_id = p_user;
  if not found then
    perform engine.raise_error('entry_not_found', jsonb_build_object('entry_id', p_entry));
  end if;
  return e;
end $$;

-- Мягкое предупреждение о дубле (док 03, раздел 6): учтённая запись с тем же отпечатком
-- (тот же день, счёт, сумма, тип, категория или заголовок). Не блокирует.
create function engine.duplicate_warnings(n public.entries) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', 'possible_duplicate', 'entry_id', n.id, 'duplicate_of', d.id,
           'occurred_on', d.occurred_on) order by d.seq), '[]')
  from public.entries d
  where d.user_id = n.user_id and d.fingerprint = n.fingerprint and d.id <> n.id and d.status = 'done'
$$;

-- 5. Движок: трата и поступление (док 03, 4.1 и 4.2).

-- Трата: остаток минус сумма. Работа и личное деньгами компании сначала тратят аванс на
-- момент траты (авто-сплит, док 03 раздел 3): работа — недостающее в «компания должна мне»;
-- личное деньгами компании — потраченный аванс в «я должен компании», недостающее свои.
-- Сплит запоминается для возврата покупки (тикет 13).
create function engine.apply_expense(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  k         bigint := e.amount_kzt_minor;
  v_company bigint := 0;
begin
  st := engine.post(st, e, 'balance', e.account_id, -engine.balance_amount(e, e.account_id));
  if e.purpose = 'work' or e.source = 'company' then
    v_company := least(k, engine.advance_of(st, e.account_id));
    st := engine.post(st, e, 'card_advance', e.account_id, -v_company);
    if e.purpose = 'work' then
      st := engine.post(st, e, 'company_owes_me', null, k - v_company);
    else
      st := engine.post(st, e, 'i_owe_company', null, v_company);
    end if;
  end if;
  st.splits := st.splits || jsonb_build_object(e.id,
    jsonb_build_object('company_part', v_company, 'own_part', k - v_company));
  return st;
end $$;

-- Поступление своих денег: только остаток.
create function engine.apply_income(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
begin
  return engine.post(st, e, 'balance', e.account_id, engine.balance_amount(e, e.account_id));
end $$;

create or replace function engine.apply_entry(st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
begin
  case e.type
    when 'adjustment' then return engine.apply_adjustment(st, e);
    when 'expense'    then return engine.apply_expense(st, e);
    when 'income'     then return engine.apply_income(st, e);
    else
      perform engine.fail('entry_type_not_supported', e, jsonb_build_object('type', e.type));
  end case;
  return st;
end $$;

-- Предупреждения пересчёта теперь видят состояние до и после записи: «остаток в минусе»
-- (spec.md: кредитов нет, минус значит пропущенную запись) выдаётся, когда запись уводит
-- остаток счёта из нуля или плюса в минус. Запись не блокируется.
drop function engine.collect_warnings(engine.replay_state, public.entries);

create function engine.collect_warnings(st_before engine.replay_state, st engine.replay_state, e public.entries)
returns engine.replay_state
language plpgsql as $$
declare
  v_account uuid;
begin
  foreach v_account in array array_remove(array[e.account_id, e.to_account_id], null) loop
    if engine.balance_of(st, v_account) < 0 and engine.balance_of(st_before, v_account) >= 0 then
      st.warnings := st.warnings || jsonb_build_array(jsonb_build_object(
        'code', 'negative_balance', 'entry_id', e.id, 'occurred_on', e.occurred_on,
        'account_id', v_account, 'balance_minor', engine.balance_of(st, v_account)));
    end if;
  end loop;
  return st;
end $$;

create or replace function engine.recompute(p_user uuid) returns jsonb
language plpgsql as $$
declare
  st     engine.replay_state := row('{}', '{}', 0, 0, '{}', '[]')::engine.replay_state;
  before engine.replay_state;
  e      public.entries;
begin
  -- Два пересчёта одного пользователя не должны перемешать журнал.
  perform pg_advisory_xact_lock(hashtextextended('engine.recompute:' || p_user::text, 0));
  delete from public.ledger_entries where user_id = p_user;

  for e in
    select * from public.entries
    where user_id = p_user and status = 'done'
    order by occurred_on, occurred_at nulls last, created_at, seq
  loop
    before := st;
    st := engine.apply_entry(st, e);
    st := engine.collect_warnings(before, st, e);
  end loop;

  return jsonb_build_object('warnings', st.warnings);
end $$;

-- 6. Публичные RPC записей (док 05). Вход: payload по контракту дока 05, суммы целыми тиынами.
-- Выход: { ok, entry_id, status, warnings }; warnings = предупреждения о дубле и пересчёта
-- ({code, entry_id, ...}: possible_duplicate, negative_balance). Ошибка: message = код,
-- details = JSON. Всё в одной транзакции: ошибка пересчёта откатывает и саму запись.

create function public.create_entry(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.entries;
begin
  perform public.assert_allowed();
  e := engine.entry_from_payload(auth.uid(), p_payload);
  e.id := gen_random_uuid();
  e.created_at := now();
  e := engine.insert_entry(engine.check_entry(e));
  return jsonb_build_object('ok', true, 'entry_id', e.id, 'status', e.status)
      || jsonb_build_object('warnings', engine.duplicate_warnings(e) || (engine.recompute(e.user_id) -> 'warnings'));
end $$;

create function public.update_entry(p_entry_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  prior public.entries;
  e     public.entries;
begin
  perform public.assert_allowed();
  prior := engine.own_entry(auth.uid(), p_entry_id);
  e := engine.entry_from_payload(prior.user_id, p_payload);
  e.id := prior.id;
  e.created_at := prior.created_at;
  e.seq := prior.seq;
  e := engine.replace_entry(engine.check_entry(e));
  return jsonb_build_object('ok', true, 'entry_id', e.id, 'status', e.status)
      || jsonb_build_object('warnings', engine.duplicate_warnings(e) || (engine.recompute(e.user_id) -> 'warnings'));
end $$;

create function public.delete_entry(p_entry_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.entries;
begin
  perform public.assert_allowed();
  e := engine.own_entry(auth.uid(), p_entry_id);
  delete from public.entries where id = e.id;
  return jsonb_build_object('ok', true) || engine.recompute(e.user_id);
end $$;

-- Нужен ли вопрос «чьими деньгами» в форме личной траты: на счёте на момент траты есть аванс.
-- p_entry_id задаётся при правке (место записи в хронологии остаётся её). Клиент не решает сам.
create function public.expense_source_needed(p_account_id uuid, p_occurred_on date, p_entry_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  a public.accounts;
  e public.entries;
  v_adv bigint;
begin
  perform public.assert_allowed();
  a := engine.own_account(auth.uid(), p_account_id);
  if p_entry_id is not null then
    e := engine.own_entry(auth.uid(), p_entry_id);
  else
    e.user_id := auth.uid();
    e.created_at := now();
  end if;
  e.occurred_on := p_occurred_on;
  v_adv := engine.advance_before(e, a.id);
  return jsonb_build_object('source_needed', v_adv > 0, 'advance_minor', v_adv);
end $$;

revoke all on function public.create_entry(jsonb), public.update_entry(uuid, jsonb), public.delete_entry(uuid),
  public.expense_source_needed(uuid, date, uuid) from public, anon;
grant execute on function public.create_entry(jsonb), public.update_entry(uuid, jsonb), public.delete_entry(uuid),
  public.expense_source_needed(uuid, date, uuid) to authenticated;

-- 7. Лента записей: поля записи, названия счёта и категории и что запись сделала со счётчиками
-- по журналу последнего пересчёта (сплит траты виден без вычислений на клиенте).
create view public.v_entries with (security_invoker = true) as
select e.id as entry_id, e.type, e.status, e.occurred_on, e.occurred_at, e.amount_minor, e.currency,
       e.account_id, a.name as account_name, e.to_account_id, e.category_id, c.name as category_name,
       e.purpose, e.source, e.in_analytics, e.comment, e.title, e.created_at, e.seq,
       coalesce(l.balance, 0)::bigint as balance_delta_minor,
       coalesce(l.advance, 0)::bigint as advance_delta_minor,
       coalesce(l.owe_me, 0)::bigint  as company_owes_me_delta_minor,
       coalesce(l.i_owe, 0)::bigint   as i_owe_company_delta_minor
from public.entries e
left join public.accounts a on a.id = e.account_id
left join public.categories c on c.id = e.category_id
left join (
  select entry_id,
         sum(delta_minor) filter (where target = 'balance')         as balance,
         sum(delta_minor) filter (where target = 'card_advance')    as advance,
         sum(delta_minor) filter (where target = 'company_owes_me') as owe_me,
         sum(delta_minor) filter (where target = 'i_owe_company')   as i_owe
  from public.ledger_entries
  where user_id = (select auth.uid())
  group by entry_id
) l on l.entry_id = e.id
where e.user_id = (select auth.uid());

revoke all on public.v_entries from anon, authenticated;
grant select on public.v_entries to authenticated;

-- Движок закрыт: его функции зовут только RPC выше.
revoke all on all functions in schema engine from public;
