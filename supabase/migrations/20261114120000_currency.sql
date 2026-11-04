-- Тикет 14: валюта (док 02, разделы 4 и 8; док 03, раздел 5; док 05; spec.md, истории 60–63).
-- Сумма записи в валюте операции (amount_minor, currency), тенговый эквивалент amount_kzt_minor
-- тремя способами (rate_source): курс Нацбанка на дату из кэша fx_rates (его наполняет Edge
-- Function fetch_rates), свой курс, сумма в тенге. Эквивалент округляется до целого тиына один
-- раз при сохранении записи: round(amount_minor × rate), rate numeric(18,8), без float. Пересчёт
-- берёт сохранённый эквивалент. Остаток в валюте счёта (engine.balance_amount, тикет 06), аванс
-- и долг в тенге. Валютный счёт ведёт операции только в своей валюте и аванса не держит.
-- Снимает запреты foreign_amount_not_supported (тикет 07) для записей на одном счёте и
-- foreign_opening_not_supported (тикет 06).
-- Скопированы с последнего определения: engine.payload_value и v_entries (20261112120000_refunds.sql
-- для ленты, 20261107120000_expense_and_income.sql для payload), engine.check_transfer
-- (20261109120000_transfers.sql), engine.check_adjustment (20261111120000_adjustments.sql),
-- engine.check_refund и refund_remaining (20261112120000_refunds.sql), engine.check_opening и
-- create_account (20261106120000_accounts.sql); прежние ветки на месте.

-- 1. Кэш курсов Нацбанка (док 02, раздел 8). Общий, без user_id: читают разрешённые
-- пользователи, пишет только Edge Function ключом service_role.
create table public.fx_rates (
  id         uuid primary key default gen_random_uuid(),
  rate_date  date not null,
  currency   text not null check (currency ~ '^[A-Z]{3}$' and currency <> 'KZT'),
  rate       numeric(18, 8) not null check (rate > 0),  -- тенге за 1 единицу валюты
  source     text not null default 'nbk' check (source = 'nbk'),
  fetched_at timestamptz not null default now(),
  constraint fx_rates_date_currency unique (rate_date, currency)
);

alter table public.fx_rates enable row level security;
create policy fx_rates_read on public.fx_rates for select to authenticated using ((select public.is_allowed()));
revoke all on public.fx_rates from anon, authenticated;
grant select on public.fx_rates to authenticated;
grant select, insert, update on public.fx_rates to service_role;

-- 2. Payload: курс можно прислать и строкой десятичной дроби ("480.12345678"), чтобы клиент
-- не гонял его через float. Остальное как в тикете 07.
create or replace function engine.payload_value(p jsonb, p_key text, p_type regtype) returns text
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
    v_ok := v_kind = 'number' or (v_kind = 'string' and p ->> p_key ~ '^[0-9]+(\.[0-9]+)?$');
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

-- 3. Тенговый эквивалент (док 03, раздел 5).

-- Курс Нацбанка на дату из кэша или null.
create function engine.nbk_rate(p_currency text, p_date date) returns numeric
language sql stable as $$
  select rate from public.fx_rates where currency = p_currency and rate_date = p_date
$$;

-- Эквивалент валютной суммы: способ обязателен.
--   nbk      курс Нацбанка на дату записи из fx_rates; нет в кэше = fx_rate_missing (форма сначала
--            зовёт fetch_rates); присланные курс и сумма в тенге отбрасываются;
--   manual   свой курс больше нуля, до 8 знаков (лишние округляются);
--   derived  сумма в тенге задана, курс выводится справочно.
-- Эквивалент целым тиыном больше нуля, курс помещается в numeric(18,8).
create function engine.convert_to_kzt(n public.entries) returns public.entries
language plpgsql stable as $$
declare
  v_kzt numeric;
begin
  if n.rate_source is null then
    perform engine.raise_error('missing_required', '{"field": "rate_source"}');
  end if;
  case n.rate_source
    when 'nbk' then
      n.rate := engine.nbk_rate(n.currency, n.occurred_on);
      if n.rate is null then
        perform engine.raise_error('fx_rate_missing', jsonb_build_object(
          'currency', n.currency, 'rate_date', n.occurred_on));
      end if;
    when 'manual' then
      if n.rate is null then
        perform engine.raise_error('missing_required', '{"field": "rate"}');
      end if;
      n.rate := round(n.rate, 8);
      if n.rate <= 0 or n.rate >= 10000000000 then
        perform engine.raise_error('field_invalid', '{"field": "rate"}');
      end if;
    when 'derived' then
      if n.amount_kzt_minor is null then
        perform engine.raise_error('missing_required', '{"field": "amount_kzt_minor"}');
      end if;
      if n.amount_kzt_minor <= 0 then
        perform engine.raise_error('amount_not_positive', '{"field": "amount_kzt_minor"}');
      end if;
      if n.amount_kzt_minor::numeric / n.amount_minor >= 10000000000 then
        perform engine.raise_error('field_invalid', '{"field": "amount_kzt_minor"}');
      end if;
      n.rate := round(n.amount_kzt_minor::numeric / n.amount_minor, 8);
      return n;
  end case;
  v_kzt := round(n.amount_minor * n.rate);
  if v_kzt <= 0 then
    perform engine.raise_error('amount_not_positive', '{"field": "amount_kzt_minor"}');
  end if;
  if v_kzt > 9223372036854775807 then
    perform engine.raise_error('field_invalid', '{"field": "amount_minor"}');
  end if;
  n.amount_kzt_minor := v_kzt::bigint;
  return n;
end $$;

-- Валюта записи на одном счёте (заменяет версию тикета 07). Валюта по умолчанию валюты счёта.
-- Тенге: эквивалент равен сумме, курса нет. Другая валюта: эквивалент по способу пересчёта.
-- Валютный счёт: операции только в его валюте (валютный счёт с операцией в третьей валюте вне
-- рамок v1, account_currency_mismatch). Пополнение от компании, изъятие аванса и погашение долга
-- только в тенге (аванс и долг в тенге, деньги компании приходят в тенге): иначе
-- foreign_amount_not_supported. Перевод в валюте своих счетов (тикет 10 уже требует одну валюту
-- счетов), иначе cross_currency_transfer.
create or replace function engine.check_entry_currency(n public.entries, a public.accounts) returns public.entries
language plpgsql stable as $$
begin
  n.currency := coalesce(n.currency, a.currency);
  perform engine.check_currency(n.currency);
  if n.type in ('company_topup', 'company_advance_return') and a.currency <> 'KZT' then
    perform engine.raise_error('foreign_advance_not_supported', jsonb_build_object(
      'account_id', a.id, 'account_currency', a.currency));
  end if;
  if n.type = 'transfer' and n.currency <> a.currency then
    perform engine.raise_error('cross_currency_transfer', jsonb_build_object(
      'account_id', a.id, 'currency', n.currency, 'account_currency', a.currency));
  end if;
  if a.currency <> 'KZT' and n.currency <> a.currency then
    perform engine.raise_error('account_currency_mismatch', jsonb_build_object(
      'currency', n.currency, 'account_currency', a.currency));
  end if;
  if n.currency = 'KZT' then
    n.amount_kzt_minor := n.amount_minor;
    n.rate := null;
    n.rate_source := null;
    return n;
  end if;
  if n.type in ('company_topup', 'company_advance_return', 'settlement') then
    perform engine.raise_error('foreign_amount_not_supported', jsonb_build_object(
      'currency', n.currency, 'account_currency', a.currency));
  end if;
  return engine.convert_to_kzt(n);
end $$;

-- Тенговый эквивалент для блока пересчёта в форме (док 04, раздел 4: «система показывает
-- тенговый эквивалент»): то же правило, что при сохранении, клиент сам не умножает. Ничего не пишет.
create function public.convert_amount(
  p_currency         text,
  p_amount_minor     bigint,
  p_occurred_on      date,
  p_rate_source      public.rate_source default null,
  p_rate             numeric default null,
  p_amount_kzt_minor bigint default null
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  n public.entries;
begin
  perform public.assert_allowed();
  perform engine.check_currency(p_currency);
  if p_amount_minor is null or p_amount_minor <= 0 then
    perform engine.raise_error('amount_not_positive');
  end if;
  n.currency := coalesce(p_currency, 'KZT'); n.amount_minor := p_amount_minor; n.occurred_on := p_occurred_on;
  if n.currency = 'KZT' then
    n.amount_kzt_minor := p_amount_minor;
  else
    if p_occurred_on is null then
      perform engine.raise_error('missing_required', '{"field": "occurred_on"}');
    end if;
    n.rate_source := p_rate_source; n.rate := p_rate; n.amount_kzt_minor := p_amount_kzt_minor;
    n := engine.convert_to_kzt(n);
  end if;
  return jsonb_build_object('amount_kzt_minor', n.amount_kzt_minor, 'rate', n.rate, 'rate_source', n.rate_source);
end $$;

revoke all on function public.convert_amount(text, bigint, date, public.rate_source, numeric, bigint) from public, anon;
grant execute on function public.convert_amount(text, bigint, date, public.rate_source, numeric, bigint) to authenticated;

-- 4. Валютный счёт без аванса (док 03, раздел 5: «валютные счета обычно аванса компании не
-- держат, аванс компании приходит в тенге»). Аванс ведётся в тенге, а свои на счёте = остаток −
-- аванс, поэтому на валютный счёт аванс не попадает ни одной записью: пополнение и изъятие (выше),
-- перевод кроме «перевода своих», корректировка остатка с авансом, «из них компании» при создании.

-- Перевод (тикет 10) плюс: перевод между валютными счетами только «перевод своих».
create or replace function engine.check_transfer(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a  public.accounts;
  b  public.accounts;
begin
  if e.account_id is null then
    perform engine.raise_error('missing_required', '{"field": "account_id"}');
  end if;
  if e.to_account_id is null then
    perform engine.raise_error('missing_required', '{"field": "to_account_id"}');
  end if;
  if e.account_id = e.to_account_id then
    perform engine.raise_error('same_account_transfer', jsonb_build_object('account_id', e.account_id));
  end if;
  a := engine.check_entry_account(n, e.account_id, 'account_id');
  b := engine.check_entry_account(n, e.to_account_id, 'to_account_id');
  if a.currency <> b.currency then
    perform engine.raise_error('cross_currency_transfer', jsonb_build_object(
      'account_id', a.id, 'currency', a.currency, 'to_account_id', b.id, 'to_currency', b.currency));
  end if;
  n.account_id := a.id;
  n.to_account_id := b.id;
  n := engine.check_entry_currency(n, a);
  if e.transfer_purpose is null then
    perform engine.raise_error('missing_required', '{"field": "transfer_purpose"}');
  end if;
  n.transfer_purpose := e.transfer_purpose;
  if a.currency <> 'KZT' and n.transfer_purpose <> 'move_own' then
    perform engine.raise_error('foreign_advance_not_supported', jsonb_build_object(
      'account_id', a.id, 'account_currency', a.currency));
  end if;
  if e.fee_minor < 0 then
    perform engine.raise_error('amount_negative', '{"field": "fee_minor"}');
  end if;
  n.fee_minor := e.fee_minor;
  if n.fee_minor > 0 then
    if e.fee_payer is null then
      perform engine.raise_error('missing_required', '{"field": "fee_payer"}');
    end if;
    n.fee_payer := e.fee_payer;
  end if;
  return n;
end $$;

-- Корректировка (тикет 12) плюс: корректировка остатка валютного счёта не меняет аванс.
create or replace function engine.check_adjustment(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  a public.accounts;
begin
  if e.adjustment_sign is null then
    perform engine.raise_error('missing_required', '{"field": "adjustment_sign"}');
  end if;
  if e.adjustment_sign not in (1, -1) then
    perform engine.raise_error('field_invalid', '{"field": "adjustment_sign"}');
  end if;
  n.adjustment_sign := e.adjustment_sign;
  n.adjustment_target := coalesce(e.adjustment_target, 'balance');

  if n.adjustment_target = 'balance' then
    a := engine.check_entry_account(n, e.account_id, 'account_id');
    n.account_id := a.id;
    if a.currency <> 'KZT' and e.adjustment_affects_advance then
      perform engine.raise_error('foreign_advance_not_supported', jsonb_build_object(
        'account_id', a.id, 'account_currency', a.currency));
    end if;
    n := engine.check_entry_currency(n, a);
    if e.adjustment_mode is null then
      perform engine.raise_error('missing_required', '{"field": "adjustment_mode"}');
    end if;
    n.adjustment_mode := e.adjustment_mode;
    n.adjustment_affects_advance := e.adjustment_affects_advance;
  else
    n.currency := coalesce(n.currency, 'KZT');
    if n.currency <> 'KZT' then
      perform engine.raise_error('foreign_amount_not_supported', jsonb_build_object('currency', n.currency));
    end if;
    n.amount_kzt_minor := n.amount_minor;
    n.rate := null;
    n.rate_source := null;
    n.adjustment_mode := 'plug_hidden';
  end if;
  n.in_analytics := n.adjustment_mode = 'plug_analytics';
  return n;
end $$;

-- Стартовый остаток (тикет 06) плюс: у валютного счёта «из них компании» только ноль;
-- foreign_opening_not_supported больше нет, эквивалент валютного остатка даёт create_account.
create or replace function engine.check_opening(p_currency text, p_total bigint, p_company bigint) returns void
language plpgsql immutable as $$
begin
  if p_total is null or p_company is null then
    perform engine.raise_error('missing_required', '{"field": "amount"}');
  end if;
  if p_total < 0 or p_company < 0 then
    perform engine.raise_error('amount_negative');
  end if;
  if p_company > p_total then
    perform engine.raise_error('opening_advance_too_big',
      jsonb_build_object('total_minor', p_total, 'company_minor', p_company));
  end if;
  if p_currency <> 'KZT' and p_company > 0 then
    perform engine.raise_error('foreign_advance_not_supported', jsonb_build_object('account_currency', p_currency));
  end if;
end $$;

-- Создание счёта (тикет 06) плюс способ пересчёта стартового остатка валютного счёта (те же
-- p_rate_source, p_rate, p_amount_kzt_minor, что у записи; курс Нацбанка на дату старта).
-- Новые параметры в конце, поэтому прежние вызовы по именам работают.
drop function public.create_account(text, public.account_type, text, date, bigint, bigint, text, text);
create function public.create_account(
  p_name             text,
  p_type             public.account_type,
  p_currency         text   default 'KZT',
  p_start_date       date   default null,
  p_total_minor      bigint default 0,
  p_company_minor    bigint default 0,
  p_bank             text   default null,
  p_mask             text   default null,
  p_rate_source      public.rate_source default null,
  p_rate             numeric default null,
  p_amount_kzt_minor bigint default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_date date := coalesce(p_start_date, (now() at time zone 'Asia/Almaty')::date);
  v_cur  text := coalesce(p_currency, 'KZT');
  v_start date;
  v_id   uuid;
  v_part record;
  n      public.entries;
begin
  perform public.assert_allowed();
  perform engine.check_account_fields(p_name, v_cur);
  if p_type is null then
    perform engine.raise_error('missing_required', '{"field": "type"}');
  end if;
  perform engine.check_opening(v_cur, p_total_minor, p_company_minor);
  select accounting_start_date into v_start from public.user_settings where user_id = v_uid;
  if v_start is null then
    perform engine.raise_error('start_not_set');
  end if;
  if v_date < v_start then
    perform engine.raise_error('entry_before_start',
      jsonb_build_object('start_date', v_date, 'accounting_start_date', v_start));
  end if;

  insert into public.accounts (user_id, name, bank, type, mask, currency, start_date)
  values (v_uid, btrim(p_name), case when p_type <> 'cash' then nullif(btrim(p_bank), '') end, p_type,
          nullif(btrim(p_mask), ''), v_cur, v_date)
  on conflict (user_id, name) do nothing
  returning id into v_id;
  if v_id is null then
    perform engine.raise_error('account_name_taken', jsonb_build_object('name', btrim(p_name)));
  end if;

  for v_part in
    select * from (values (p_total_minor - p_company_minor, false), (p_company_minor, true)) p (amount, with_advance)
    where amount > 0
  loop
    n := null;
    n.occurred_on := v_date; n.amount_minor := v_part.amount; n.currency := v_cur;
    n.amount_kzt_minor := v_part.amount;
    if v_cur <> 'KZT' then
      n.rate_source := p_rate_source; n.rate := p_rate; n.amount_kzt_minor := p_amount_kzt_minor;
      n := engine.convert_to_kzt(n);
    end if;
    insert into public.entries (user_id, type, occurred_on, amount_minor, currency, amount_kzt_minor, rate,
                                rate_source, account_id, adjustment_mode, adjustment_sign, adjustment_target,
                                adjustment_affects_advance, in_analytics, title)
    values (v_uid, 'adjustment', v_date, v_part.amount, v_cur, n.amount_kzt_minor, n.rate, n.rate_source, v_id,
            'plug_hidden', 1, 'balance', v_part.with_advance, false, 'Стартовый остаток');
  end loop;

  return jsonb_build_object('ok', true, 'account_id', v_id) || engine.recompute(v_uid);
end $$;

revoke all on function public.create_account(text, public.account_type, text, date, bigint, bigint, text, text,
  public.rate_source, numeric, bigint) from public, anon;
grant execute on function public.create_account(text, public.account_type, text, date, bigint, bigint, text, text,
  public.rate_source, numeric, bigint) to authenticated;

-- 5. Возврат покупки (тикет 13) плюс валютная трата: возврат в валюте траты и по её курсу
-- (док 03, 4.8: откатывается фактически списанный эквивалент; курсовая разница отдельной
-- корректировкой). Эквивалент по накопленной сумме возвратов, как восстановление в пересчёте:
-- round(эквивалент траты × (возвращено другими + этот) / сумма траты) − эквиваленты других,
-- поэтому полный возврат закрывает эквивалент траты без потери тиына. Присланные валюта и курс
-- отбрасываются. Сумма всех возвратов в валюте траты не больше траты.
create or replace function engine.check_refund(n public.entries, e public.entries) returns public.entries
language plpgsql stable as $$
declare
  p     public.entries;
  a     public.accounts;
  v_amt bigint;
  v_kzt bigint;
begin
  if e.parent_entry_id is null then
    perform engine.raise_error('missing_required', '{"field": "parent_entry_id"}');
  end if;
  p := engine.own_entry(n.user_id, e.parent_entry_id);
  if p.type <> 'expense' or p.status <> 'done' then
    perform engine.raise_error('refund_parent_not_expense', jsonb_build_object(
      'parent_entry_id', p.id, 'type', p.type, 'status', p.status));
  end if;
  a := engine.check_entry_account(n, p.account_id, 'account_id');
  n.account_id := a.id;
  n.currency := p.currency;
  if p.currency = 'KZT' then
    n := engine.check_entry_currency(n, a);
  else
    select coalesce(sum(amount_minor), 0)::bigint, coalesce(sum(amount_kzt_minor), 0)::bigint
      into v_amt, v_kzt
    from public.entries
    where parent_entry_id = p.id and type = 'refund' and status = 'done' and id is distinct from n.id;
    if v_amt + n.amount_minor > p.amount_minor then
      perform engine.raise_error('refund_too_big', jsonb_build_object(
        'parent_entry_id', p.id, 'available_minor', p.amount_minor - v_amt, 'amount_minor', n.amount_minor));
    end if;
    n.rate := p.rate;
    n.rate_source := p.rate_source;
    n.amount_kzt_minor := round(p.amount_kzt_minor::numeric * (v_amt + n.amount_minor) / p.amount_minor)::bigint
                          - v_kzt;
    if n.amount_kzt_minor <= 0 then
      perform engine.raise_error('amount_not_positive', '{"field": "amount_kzt_minor"}');
    end if;
  end if;
  if n.occurred_on < p.occurred_on then
    perform engine.raise_error('refund_before_expense', jsonb_build_object(
      'occurred_on', n.occurred_on, 'parent_entry_id', p.id, 'parent_occurred_on', p.occurred_on));
  end if;
  n.parent_entry_id := p.id;
  n.category_id := p.category_id;
  n.purpose := p.purpose;
  n.source := p.source;
  return n;
end $$;

-- Сколько ещё можно вернуть по трате, в валюте траты (для тенговой траты как раньше).
create or replace function public.refund_remaining(p_parent_entry_id uuid, p_entry_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p          public.entries;
  v_refunded bigint;
begin
  perform public.assert_allowed();
  p := engine.own_entry(auth.uid(), p_parent_entry_id);
  if p.type <> 'expense' or p.status <> 'done' then
    perform engine.raise_error('refund_parent_not_expense', jsonb_build_object(
      'parent_entry_id', p.id, 'type', p.type, 'status', p.status));
  end if;
  select coalesce(sum(amount_minor), 0)::bigint into v_refunded
  from public.entries
  where parent_entry_id = p.id and status = 'done' and id is distinct from p_entry_id;
  return jsonb_build_object('parent_amount_minor', p.amount_minor, 'refunded_minor', v_refunded,
                            'remaining_minor', p.amount_minor - v_refunded, 'currency', p.currency);
end $$;

-- 6. Лента: тенговый эквивалент, курс, способ пересчёта и валюта счёта, в которой дельты остатка
-- (новые колонки в конце).
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
       e.amount_kzt_minor, e.rate, e.rate_source, a.currency as account_currency
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

revoke all on all functions in schema engine from public;
