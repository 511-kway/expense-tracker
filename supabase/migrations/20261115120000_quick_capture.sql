-- Тикет 15: быстрый ввод и инбокс (ADR-0009; док 03, раздел 9; док 04, разделы 4.1 и 5; док 05
-- quick_capture и promote_draft; spec.md, истории 69–75).
-- Быстрый ввод только для траты: сумма, счёт, личное/работа, короткий текст (категория по желанию).
-- Если движку хватает данных (работа на любом счёте; личное на счёте без аванса на дату), трата
-- сразу учтена; личное на счёте с авансом = черновик с source_pending («источник?»): непонятно,
-- чьими деньгами. Черновик в пересчёт не входит (engine.recompute берёт только done).
-- Категория траты теперь требуется полной формой (create_entry / update_entry), а не проверкой
-- типа: учтённая трата из быстрого ввода может быть без категории и висит в инбоксе.
-- Скопированы с последнего определения: engine.check_expense и create_entry
-- (20261107120000_expense_and_income.sql), update_entry (20261112120000_refunds.sql), preview_entry
-- (20261113120000_preview.sql), v_entries (20261114120000_currency.sql); прежние ветки на месте.

-- 1. Проверка траты: всё как в тикете 07, кроме категории (её требует полная форма).
create or replace function engine.check_expense(n public.entries, e public.entries) returns public.entries
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
  if e.category_id is not null then
    n.category_id := (engine.own_category(n.user_id, e.category_id)).id;
  end if;
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

-- Полная форма: у траты категория обязательна (ADR-0009: «полная форма по-прежнему требует категорию»).
create function engine.require_category(n public.entries) returns void
language plpgsql immutable as $$
begin
  if n.type = 'expense' and n.category_id is null then
    perform engine.raise_error('missing_required', '{"field": "category_id"}');
  end if;
end $$;

-- 2. Сохранение. Ответ всех RPC записей: { ok, entry_id, status, warnings }.

create function engine.saved(e public.entries, p_recompute boolean) returns jsonb
language plpgsql as $$
begin
  return jsonb_build_object('ok', true, 'entry_id', e.id, 'status', e.status,
           'source_pending', e.source_pending)
      || jsonb_build_object('warnings', engine.duplicate_warnings(e)
           || case when p_recompute then engine.recompute(e.user_id) -> 'warnings' else '[]'::jsonb end);
end $$;

create or replace function public.create_entry(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.entries;
begin
  perform public.assert_allowed();
  e := engine.entry_from_payload(auth.uid(), p_payload);
  e.id := gen_random_uuid();
  e.created_at := now();
  e := engine.check_entry(e);
  perform engine.require_category(e);
  e := engine.insert_entry(e);
  return engine.saved(e, true);
end $$;

-- Правка записи (тело update_entry тикета 13): своя запись prior, payload целиком. Полная форма
-- требует категорию траты, дозаполнение черновика нет (p_category_required).
create function engine.update_entry(prior public.entries, p_payload jsonb, p_category_required boolean)
returns jsonb
language plpgsql as $$
declare
  e public.entries;
begin
  e := engine.entry_from_payload(prior.user_id, p_payload);
  e.id := prior.id;
  e.created_at := prior.created_at;
  e.seq := prior.seq;
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

create or replace function public.update_entry(p_entry_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.assert_allowed();
  return engine.update_entry(engine.own_entry(auth.uid(), p_entry_id), p_payload, true);
end $$;

-- 3. Быстрый ввод (ADR-0009). Payload: amount_minor, account_id, purpose, title, по желанию
-- occurred_on (по умолчанию сегодня по Алматы), occurred_at, category_id, comment, source и поля
-- валюты (currency, rate_source, rate, amount_kzt_minor), как у create_entry. Тип всегда трата,
-- присланные type и status отбрасываются. Черновик проверяется как учтённая трата «своими»
-- (всё, кроме источника, должно быть верно), затем хранится без источника с source_pending.
-- Ответ: { ok, entry_id, status, source_pending, warnings }; у черновика пересчёта нет
-- (счётчики не меняются), предупреждения только о дубле.
create function public.quick_capture(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e     public.entries;
  v_adv bigint := 0;
begin
  perform public.assert_allowed();
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    perform engine.raise_error('field_invalid', '{"field": "payload"}');
  end if;
  e := engine.entry_from_payload(auth.uid(),
         (p_payload - 'status') || '{"type": "expense"}'::jsonb);
  e.status := 'done';
  e.occurred_on := coalesce(e.occurred_on, (now() at time zone 'Asia/Almaty')::date);
  e.id := gen_random_uuid();
  e.created_at := now();
  if e.purpose = 'personal' and e.source is null and e.account_id is not null then
    perform engine.own_account(e.user_id, e.account_id);
    v_adv := engine.advance_before(e, e.account_id);
    if v_adv > 0 then
      e.source := 'own';
    end if;
  end if;
  e := engine.check_entry(e);
  if v_adv > 0 then
    e.status := 'draft';
    e.source := null;
    e.source_pending := true;
  end if;
  e := engine.insert_entry(e);
  return engine.saved(e, e.status = 'done');
end $$;

-- 4. Дозаполнение черновика (док 05 promote_draft): тот же payload, что у update_entry (в том
-- числе источник); запись становится учтённой (присланный status отбрасывается), пересчёт.
-- Категория не обязательна: учтённая трата без категории остаётся в инбоксе (ADR-0009).
create function public.promote_draft(p_entry_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  prior public.entries;
begin
  perform public.assert_allowed();
  prior := engine.own_entry(auth.uid(), p_entry_id);
  if prior.status <> 'draft' then
    perform engine.raise_error('entry_not_draft', jsonb_build_object('entry_id', prior.id));
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    perform engine.raise_error('field_invalid', '{"field": "payload"}');
  end if;
  return engine.update_entry(prior, (p_payload - 'status'), false);
end $$;

revoke all on function public.quick_capture(jsonb), public.promote_draft(uuid, jsonb) from public, anon;
grant execute on function public.quick_capture(jsonb), public.promote_draft(uuid, jsonb) to authenticated;

-- 4a. Предпросмотр дозаполнения (ADR-0010).
-- Тело тикета 08 без изменений, кроме одной ветки: у черновика предпросмотр зовёт promote_draft
-- (дозаполнение), а не update_entry, поэтому показывает ровно то, что сделает «Сохранить» в инбоксе.
-- Предпросмотр (док 05): тот же payload, что create_entry, или p_entry_id плюс payload для правки.
-- Ответ: { ok, entry_id (при правке, у новой записи null), status, warnings,
--          accounts: [{account_id, name, currency}] — затронутые счета: счёт и «куда» записи (и её
--                    прежние счета при правке), затем любые другие, у которых что-то сдвинулось,
--          before / after / deltas: { accounts: {<account_id>: {balance_minor, advance_minor, own_minor}},
--                                     company_owes_me_minor, i_owe_company_minor } }.
-- Ошибка проверки или пересчёта приходит ровно так же, как у сохранения (message = код, details =
-- JSON). У новой записи id в предупреждениях и ошибках временный: такой записи не будет.
create or replace function public.preview_entry(p_payload jsonb, p_entry_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user   uuid;
  v_before jsonb;
  v_after  jsonb;
  v_saved  jsonb;
  prior    public.entries;
  e        public.entries;
  v_list   jsonb;
  v_ids    text[];
  v_part   text;
  v_out    jsonb := '{}';
begin
  perform public.assert_allowed();
  v_user := auth.uid();
  if p_entry_id is not null then
    prior := engine.own_entry(v_user, p_entry_id);
  end if;
  v_before := engine.counters(v_user);

  begin
    if p_entry_id is null then
      v_saved := public.create_entry(p_payload);
    elsif prior.status = 'draft' then
      v_saved := public.promote_draft(p_entry_id, p_payload);
    else
      v_saved := public.update_entry(p_entry_id, p_payload);
    end if;
    select * into e from public.entries where id = (v_saved ->> 'entry_id')::uuid;
    v_after := engine.counters(v_user);
    -- Откат всего, что сделало сохранение; переменные остаются.
    raise exception using errcode = 'PV001', message = 'preview_rollback';
  exception when sqlstate 'PV001' then
    null;
  end;

  -- Затронутые счета: свои счета записи первыми, затем сдвинувшиеся, по названию.
  select coalesce(jsonb_agg(jsonb_build_object('account_id', a.id, 'name', a.name, 'currency', a.currency)
                            order by x.ord, a.name), '[]'::jsonb),
         coalesce(array_agg(a.id::text order by x.ord, a.name), '{}')
    into v_list, v_ids
  from (
    select id, min(ord) as ord from (
      select u.id, u.ord
      from unnest(array[e.account_id, e.to_account_id, prior.account_id, prior.to_account_id])
           with ordinality as u(id, ord)
      union all
      select k::uuid, 100
      from jsonb_object_keys(v_after -> 'accounts') as k
      where (v_before -> 'accounts' -> k) is distinct from (v_after -> 'accounts' -> k)
    ) s
    where id is not null
    group by id
  ) x
  join public.accounts a on a.id = x.id and a.user_id = v_user;

  foreach v_part in array array['before', 'after', 'deltas'] loop
    v_out := v_out || jsonb_build_object(v_part, jsonb_build_object(
      'accounts', coalesce((
        select jsonb_object_agg(id, case v_part
          when 'before' then v_before -> 'accounts' -> id
          when 'after'  then v_after -> 'accounts' -> id
          else (select jsonb_object_agg(k, (v_after -> 'accounts' -> id ->> k)::bigint
                                           - (v_before -> 'accounts' -> id ->> k)::bigint)
                from unnest(array['balance_minor', 'advance_minor', 'own_minor']) as k)
          end)
        from unnest(v_ids) as id), '{}'::jsonb),
      'company_owes_me_minor', case v_part
        when 'before' then (v_before ->> 'company_owes_me_minor')::bigint
        when 'after'  then (v_after ->> 'company_owes_me_minor')::bigint
        else (v_after ->> 'company_owes_me_minor')::bigint - (v_before ->> 'company_owes_me_minor')::bigint end,
      'i_owe_company_minor', case v_part
        when 'before' then (v_before ->> 'i_owe_company_minor')::bigint
        when 'after'  then (v_after ->> 'i_owe_company_minor')::bigint
        else (v_after ->> 'i_owe_company_minor')::bigint - (v_before ->> 'i_owe_company_minor')::bigint end));
  end loop;

  return jsonb_build_object(
           'ok', true,
           'entry_id', case when p_entry_id is null then null else v_saved -> 'entry_id' end,
           'status', v_saved -> 'status',
           'warnings', v_saved -> 'warnings',
           'accounts', v_list)
      || v_out;
end $$;


-- 4b. Лента: черновик «источник?» (новая колонка в конце).
create or replace view public.v_entries with (security_invoker = true) as
select e.id as entry_id, e.type, e.status, e.occurred_on, e.occurred_at, e.amount_minor, e.currency,
       e.account_id, a.name as account_name, e.to_account_id, e.category_id, c.name as category_name,
       e.purpose, e.source, e.in_analytics, e.comment, e.title, e.created_at, e.seq,
       coalesce(l.balance, 0)::bigint as balance_delta_minor,
       coalesce(l.advance, 0)::bigint as advance_delta_minor,
       coalesce(l.owe_me, 0)::bigint  as company_owes_me_delta_minor,
       coalesce(l.i_owe, 0)::bigint   as i_owe_company_delta_minor,
       e.fee_minor, e.fee_payer,
       e.transfer_purpose, t.name as to_account_name,
       coalesce(l.to_balance, 0)::bigint as to_balance_delta_minor,
       coalesce(l.to_advance, 0)::bigint as to_advance_delta_minor,
       e.settlement_direction,
       e.adjustment_target, e.adjustment_sign, e.adjustment_mode, e.adjustment_affects_advance,
       e.parent_entry_id, p.occurred_on as parent_occurred_on, p.amount_minor as parent_amount_minor,
       p.title as parent_title,
       coalesce(r.refunded, 0)::bigint as refunded_minor,
       e.amount_kzt_minor, e.rate, e.rate_source, a.currency as account_currency,
       e.source_pending
from public.entries e
left join public.accounts a on a.id = e.account_id
left join public.accounts t on t.id = e.to_account_id
left join public.categories c on c.id = e.category_id
left join public.entries p on p.id = e.parent_entry_id
left join (
  select parent_entry_id, sum(amount_minor) as refunded
  from public.entries
  where user_id = (select auth.uid()) and type = 'refund' and status = 'done'
  group by parent_entry_id
) r on r.parent_entry_id = e.id
left join (
  select l.entry_id,
         sum(l.delta_minor) filter (where l.target = 'balance' and l.account_id = x.account_id)         as balance,
         sum(l.delta_minor) filter (where l.target = 'card_advance' and l.account_id = x.account_id)    as advance,
         sum(l.delta_minor) filter (where l.target = 'company_owes_me')                                  as owe_me,
         sum(l.delta_minor) filter (where l.target = 'i_owe_company')                                    as i_owe,
         sum(l.delta_minor) filter (where l.target = 'balance' and l.account_id = x.to_account_id)      as to_balance,
         sum(l.delta_minor) filter (where l.target = 'card_advance' and l.account_id = x.to_account_id) as to_advance
  from public.ledger_entries l
  join public.entries x on x.id = l.entry_id
  where l.user_id = (select auth.uid())
  group by l.entry_id
) l on l.entry_id = e.id
where e.user_id = (select auth.uid());

revoke all on public.v_entries from anon, authenticated;
grant select on public.v_entries to authenticated;

-- 5. Инбокс (док 04, раздел 5): всё, что ждёт внимания владельца. kind:
--   draft        черновик (source_pending = «источник?»);
--   no_category  учтённая трата без категории («без категории»).
-- Точка расширения: тикет 16 добавит новые заметки (kind = 'note') веткой union all, колонки
-- заметки в конце (create or replace view). Порядок для экрана: черновики первыми, затем новее раньше.
create view public.v_inbox with (security_invoker = true) as
select case when e.status = 'draft' then 'draft' else 'no_category' end as kind,
       e.id as entry_id, e.occurred_on, e.amount_minor, e.currency, e.account_id, a.name as account_name,
       e.purpose, e.title, e.comment, e.source_pending, e.created_at
from public.entries e
left join public.accounts a on a.id = e.account_id
where e.user_id = (select auth.uid())
  and (e.status = 'draft' or (e.type = 'expense' and e.category_id is null));

-- Бейдж инбокса: число элементов считает сервер.
create view public.v_inbox_count with (security_invoker = true) as
select count(*)::int as items from public.v_inbox;

revoke all on public.v_inbox, public.v_inbox_count from anon, authenticated;
grant select on public.v_inbox, public.v_inbox_count to authenticated;

revoke all on all functions in schema engine from public;
