-- Тикет 08: предпросмотр эффекта (ADR-0010; spec.md, история 32; док 05 preview_entry).
-- preview_entry зовёт ровно create_entry / update_entry (та же проверка, тот же пересчёт, те же
-- ошибки и предупреждения), снимает четыре счётчика до и после и откатывает подтранзакцию:
-- в базе ничего не остаётся. Своих правил у предпросмотра нет, поэтому он не может разойтись с
-- сохранением. Движок и RPC записей не переопределяются.

-- Счётчики пользователя по журналу последнего пересчёта: остаток, аванс и свои каждого счёта (все
-- счета, без строк журнала нули; свои = остаток − аванс, как в v_account_balances) и обе стороны долга.
create function engine.counters(p_user uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'accounts', coalesce((
      select jsonb_object_agg(a.id, jsonb_build_object(
               'balance_minor', coalesce(l.balance, 0)::bigint,
               'advance_minor', coalesce(l.advance, 0)::bigint,
               'own_minor', (coalesce(l.balance, 0) - coalesce(l.advance, 0))::bigint))
      from public.accounts a
      left join (
        select account_id,
               sum(delta_minor) filter (where target = 'balance')      as balance,
               sum(delta_minor) filter (where target = 'card_advance') as advance
        from public.ledger_entries
        where user_id = p_user and account_id is not null
        group by account_id
      ) l on l.account_id = a.id
      where a.user_id = p_user), '{}'::jsonb),
    'company_owes_me_minor', coalesce((
      select sum(delta_minor) from public.ledger_entries
      where user_id = p_user and target = 'company_owes_me'), 0)::bigint,
    'i_owe_company_minor', coalesce((
      select sum(delta_minor) from public.ledger_entries
      where user_id = p_user and target = 'i_owe_company'), 0)::bigint)
$$;

-- Предпросмотр (док 05): тот же payload, что create_entry, или p_entry_id плюс payload для правки.
-- Ответ: { ok, entry_id (при правке, у новой записи null), status, warnings,
--          accounts: [{account_id, name, currency}] — затронутые счета: счёт и «куда» записи (и её
--                    прежние счета при правке), затем любые другие, у которых что-то сдвинулось,
--          before / after / deltas: { accounts: {<account_id>: {balance_minor, advance_minor, own_minor}},
--                                     company_owes_me_minor, i_owe_company_minor } }.
-- Ошибка проверки или пересчёта приходит ровно так же, как у сохранения (message = код, details =
-- JSON). У новой записи id в предупреждениях и ошибках временный: такой записи не будет.
create function public.preview_entry(p_payload jsonb, p_entry_id uuid default null) returns jsonb
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

revoke all on function public.preview_entry(jsonb, uuid) from public, anon;
grant execute on function public.preview_entry(jsonb, uuid) to authenticated;

revoke all on all functions in schema engine from public;
