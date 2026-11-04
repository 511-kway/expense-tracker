-- Экспорт (док 04, раздел 9; тикет 17). Две выборки, из которых Edge Function `export` строит два
-- плоских файла по схеме supabase/functions/_shared/schema.ts (схема импорта, док 04, раздел 8).
-- Деньги здесь целыми минимальными единицами со знаком журнала; знак и формат в файле ставит схема.

-- 1. Файл expenses: учтённые записи (черновики не выгружаются: импорт их не создаёт, ADR-0004).
-- Счета и категории названиями (импорт сопоставляет по точному названию). external_id: свой у
-- импортированной записи, иначе id записи, чтобы повторный импорт выгрузки не плодил дубли.
-- Возврат покупки ссылается на трату её external_id (parent_external_id).
create view public.v_export_entries with (security_invoker = true) as
select e.id as entry_id, e.occurred_on, e.occurred_at, e.created_at, e.seq,
       e.type, a.name as account_name, e.amount_minor, e.currency, c.name as category_name,
       e.source, e.purpose, e.transfer_purpose, t.name as to_account_name, e.fee_minor, e.fee_payer,
       e.comment, e.title, coalesce(e.external_id, e.id::text) as external_id,
       e.settlement_direction, e.adjustment_target, e.adjustment_mode, e.adjustment_sign,
       e.adjustment_affects_advance,
       case when p.id is not null then coalesce(p.external_id, p.id::text) end as parent_external_id,
       e.rate, e.rate_source, e.amount_kzt_minor, e.in_analytics
from public.entries e
left join public.accounts a on a.id = e.account_id
left join public.accounts t on t.id = e.to_account_id
left join public.categories c on c.id = e.category_id
left join public.entries p on p.id = e.parent_entry_id
where e.user_id = (select auth.uid()) and e.status = 'done';

revoke all on public.v_export_entries from anon, authenticated;
grant select on public.v_export_entries to authenticated;

-- 2. Файл company_settlement: движения с компанией. Из разбора долга (v_settlement_breakdown,
-- строка = запись × сторона) одна строка на запись: изменение каждой стороны и обе стороны после
-- записи в порядке пересчёта, плюс итог после (компания должна мне − я должен компании).
-- Накопление идёт по всей истории внутри выборки, поэтому фильтр по периоду снаружи не меняет
-- сторон «после».
create view public.v_settlement_movements with (security_invoker = true) as
select m.*,
       (sum(m.company_owes_me_delta_minor) over w)::bigint as company_owes_me_after_minor,
       (sum(m.i_owe_company_delta_minor) over w)::bigint as i_owe_company_after_minor,
       (sum(m.company_owes_me_delta_minor - m.i_owe_company_delta_minor) over w)::bigint as net_after_minor
from (
  select b.entry_id, b.occurred_on, b.occurred_at, b.created_at, b.seq, b.type, b.account_name,
         b.to_account_name, b.category_name, b.purpose, b.source, b.transfer_purpose, b.settlement_direction,
         b.title, b.parent_title, coalesce(e.external_id, e.id::text) as external_id, 'KZT'::text as currency,
         coalesce(sum(b.delta_minor) filter (where b.side = 'company_owes_me'), 0)::bigint as company_owes_me_delta_minor,
         coalesce(sum(b.delta_minor) filter (where b.side = 'i_owe_company'), 0)::bigint as i_owe_company_delta_minor
  from public.v_settlement_breakdown b
  join public.entries e on e.id = b.entry_id
  group by b.entry_id, b.occurred_on, b.occurred_at, b.created_at, b.seq, b.type, b.account_name,
           b.to_account_name, b.category_name, b.purpose, b.source, b.transfer_purpose, b.settlement_direction,
           b.title, b.parent_title, e.external_id, e.id
) m
window w as (order by m.occurred_on, m.occurred_at nulls last, m.created_at, m.seq);

revoke all on public.v_settlement_movements from anon, authenticated;
grant select on public.v_settlement_movements to authenticated;
