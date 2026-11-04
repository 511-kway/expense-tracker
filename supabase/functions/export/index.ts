// Edge Function export: настоящие зависимости для handler.ts. Всё читается клиентом с JWT
// пользователя: выборки security_invoker, RLS отдаёт только свои строки разрешённого (ADR-0007).
// Деньги и курс читаются из базы текстом (`::text`), чтобы не проходить через float.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { type Deps, handleExport, type Period } from "./handler.ts";
import type { ExportEntryRow, SettlementMovementRow } from "../_shared/schema.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
/** Страница выборки: PostgREST отдаёт не больше max_rows строк за запрос. */
const PAGE = 1000;

function userClient(authorization: string) {
  return createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
}

const ENTRY_SELECT = [
  "occurred_on",
  "type",
  "account_name",
  "amount_minor::text",
  "currency",
  "category_name",
  "source",
  "purpose",
  "transfer_purpose",
  "to_account_name",
  "fee_minor::text",
  "fee_payer",
  "comment",
  "title",
  "external_id",
  "settlement_direction",
  "adjustment_target",
  "adjustment_mode",
  "adjustment_sign",
  "adjustment_affects_advance",
  "parent_external_id",
  "rate::text",
  "rate_source",
  "amount_kzt_minor::text",
  "in_analytics",
].join(",");

const MOVEMENT_SELECT = [
  "occurred_on",
  "type",
  "account_name",
  "to_account_name",
  "title",
  "parent_title",
  "category_name",
  "purpose",
  "source",
  "transfer_purpose",
  "settlement_direction",
  "currency",
  "company_owes_me_delta_minor::text",
  "i_owe_company_delta_minor::text",
  "company_owes_me_after_minor::text",
  "i_owe_company_after_minor::text",
  "net_after_minor::text",
  "external_id",
].join(",");

/** Вся выборка за период в порядке пересчёта, страницами. */
async function loadAll<T>(authorization: string, view: string, select: string, period: Period): Promise<T[]> {
  const client = userClient(authorization);
  const rows: T[] = [];
  for (let offset = 0;; offset += PAGE) {
    let query = client.from(view).select(select);
    if (period.from) query = query.gte("occurred_on", period.from);
    if (period.to) query = query.lte("occurred_on", period.to);
    const { data, error } = await query
      .order("occurred_on").order("occurred_at", { nullsFirst: false }).order("created_at").order("seq")
      .range(offset, offset + PAGE - 1);
    if (error) throw error;
    rows.push(...(data as T[]));
    if (data.length < PAGE) return rows;
  }
}

const deps: Deps = {
  async isAllowed(authorization) {
    if (!authorization) return false;
    const { data, error } = await userClient(authorization).rpc("is_allowed");
    return !error && data === true;
  },
  loadEntries: (authorization, period) =>
    loadAll<ExportEntryRow>(authorization, "v_export_entries", ENTRY_SELECT, period),
  loadMovements: (authorization, period) =>
    loadAll<SettlementMovementRow>(authorization, "v_settlement_movements", MOVEMENT_SELECT, period),
};

Deno.serve((req) => handleExport(req, deps));
