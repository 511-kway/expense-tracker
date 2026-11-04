-- Тикет 19: обзор (spec.md, история 90; док 04, раздел 10; док 05 v_overview).
-- Агрегаты главного экрана, только из журнала и записей, ничего не хранится:
--   всего денег, свои деньги, деньги компании на картах (в тенге), итог с компанией,
--   остаток и аванс по каждому счёту, личные траты за период, число элементов инбокса.
--
-- Решения (записаны в .scratch/v1/spec/README.md, тикет 19):
--   * Валютный счёт аванса не держит (тикет 14), его остаток целиком свои деньги. В итоги в тенге
--     он входит по последнему курсу Нацбанка из кэша fx_rates на сегодня или раньше:
--     round(остаток × курс), numeric, половина от нуля. Курса в кэше нет: счёт в итоги не входит
--     и перечислен в unconverted, экран говорит об этом. Курс в ответе строкой (без float на клиенте).
--   * Личные траты = учтённые траты с назначением «личное» и признаком «в разрезах трат»
--     (своими или деньгами компании) + корректировки остатка в минус «в разрезах трат» своими
--     деньгами (без аванса) − возвраты покупок по таким тратам. Всё в тенговом эквиваленте.
--     Возврат считается в периоде своей даты (период может уйти в минус). Черновики, рабочие
--     траты, комиссии и скрытые корректировки не считаются.
--   * Период включительно; без параметров текущий месяц по часовому поясу учёта (Asia/Almaty),
--     одна граница null = без границы с этой стороны; начало позже конца = period_invalid.

create function public.overview(p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid      uuid := auth.uid();
  v_today    date;
  v_from     date := p_from;
  v_to       date := p_to;
  v_accounts jsonb;
  v_unconv   jsonb;
  v_total    bigint;
  v_company  bigint;
  v_debt     public.v_company_settlement;
  v_exp      bigint;
  v_adj      bigint;
  v_ref      bigint;
  v_inbox    int;
begin
  perform public.assert_allowed();
  v_today := (now() at time zone coalesce(
    (select timezone from public.user_settings where user_id = v_uid), 'Asia/Almaty'))::date;
  if p_from is null and p_to is null then
    v_from := date_trunc('month', v_today)::date;
    v_to := (date_trunc('month', v_today) + interval '1 month - 1 day')::date;
  end if;
  if v_from > v_to then
    perform engine.raise_error('period_invalid', jsonb_build_object('from', v_from, 'to', v_to));
  end if;

  -- Счета с остатком в тенге: тенговый как есть, валютный по последнему курсу из кэша.
  with rows as (
    select b.account_id, b.name, b.type, b.bank, b.mask, b.currency, b.balance_minor, b.advance_minor,
           b.own_minor, r.rate, r.rate_date,
           case when b.currency = 'KZT' then b.balance_minor
                when r.rate is not null then round(b.balance_minor * r.rate)::bigint end as balance_kzt_minor
    from public.v_account_balances b
    left join lateral (
      select f.rate, f.rate_date from public.fx_rates f
      where b.currency <> 'KZT' and f.currency = b.currency and f.rate_date <= v_today
      order by f.rate_date desc limit 1
    ) r on true
    where not b.is_archived
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'account_id', account_id, 'name', name, 'type', type, 'bank', bank, 'mask', mask,
           'currency', currency, 'balance_minor', balance_minor, 'advance_minor', advance_minor,
           'own_minor', own_minor, 'balance_kzt_minor', balance_kzt_minor,
           'rate', trim_scale(rate)::text, 'rate_date', rate_date)
           order by balance_kzt_minor desc nulls last, name), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('account_id', account_id, 'name', name, 'currency', currency,
           'balance_minor', balance_minor) order by name) filter (where balance_kzt_minor is null), '[]'),
         coalesce(sum(balance_kzt_minor), 0)::bigint,
         coalesce(sum(advance_minor), 0)::bigint
    into v_accounts, v_unconv, v_total, v_company
  from rows;
  -- Архивный счёт держит нулевые остаток и аванс (архив только при нуле), в итоги не входит.

  select * into v_debt from public.v_company_settlement;

  select coalesce(sum(e.amount_kzt_minor) filter (where e.type = 'expense'), 0)::bigint,
         coalesce(sum(e.amount_kzt_minor) filter (where e.type = 'adjustment'), 0)::bigint
    into v_exp, v_adj
  from public.entries e
  where e.user_id = v_uid and e.status = 'done' and e.in_analytics
    and (v_from is null or e.occurred_on >= v_from) and (v_to is null or e.occurred_on <= v_to)
    and ((e.type = 'expense' and e.purpose = 'personal')
         or (e.type = 'adjustment' and e.adjustment_target = 'balance' and e.adjustment_sign = -1
             and not e.adjustment_affects_advance));

  select coalesce(sum(r.amount_kzt_minor), 0)::bigint into v_ref
  from public.entries r
  join public.entries p on p.id = r.parent_entry_id
  where r.user_id = v_uid and r.type = 'refund' and r.status = 'done'
    and p.purpose = 'personal' and p.in_analytics
    and (v_from is null or r.occurred_on >= v_from) and (v_to is null or r.occurred_on <= v_to);

  select items into v_inbox from public.v_inbox_count;

  return jsonb_build_object(
    'total_balance_minor', v_total,
    'total_own_minor', v_total - v_company,
    'total_company_advance_minor', v_company,
    'company_owes_me_minor', v_debt.company_owes_me_minor,
    'i_owe_company_minor', v_debt.i_owe_company_minor,
    'net_minor', v_debt.net_minor,
    'personal', jsonb_build_object(
      'from', v_from, 'to', v_to,
      'expenses_minor', v_exp, 'adjustments_minor', v_adj, 'refunds_minor', v_ref,
      'spent_minor', v_exp + v_adj - v_ref),
    'accounts', v_accounts,
    'unconverted', v_unconv,
    'inbox_items', coalesce(v_inbox, 0),
    'today', v_today);
end $$;

revoke all on function public.overview(date, date) from public, anon;
grant execute on function public.overview(date, date) to authenticated;

-- Выборка v_overview (док 05): агрегаты за текущий месяц одной строкой.
create view public.v_overview with (security_invoker = true) as
select (o ->> 'total_balance_minor')::bigint                 as total_balance_minor,
       (o ->> 'total_own_minor')::bigint                     as total_own_minor,
       (o ->> 'total_company_advance_minor')::bigint         as total_company_advance_minor,
       (o ->> 'company_owes_me_minor')::bigint               as company_owes_me_minor,
       (o ->> 'i_owe_company_minor')::bigint                 as i_owe_company_minor,
       (o ->> 'net_minor')::bigint                           as net_minor,
       (o -> 'personal' ->> 'spent_minor')::bigint           as personal_spend_period_minor,
       (o -> 'personal' ->> 'from')::date                    as period_from,
       (o -> 'personal' ->> 'to')::date                      as period_to
from public.overview() o;

revoke all on public.v_overview from anon, authenticated;
grant select on public.v_overview to authenticated;
