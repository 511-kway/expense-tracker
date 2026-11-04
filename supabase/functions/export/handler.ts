// export(from?, to?, format) → zip из двух файлов (док 04, раздел 9): `expenses` (учтённые записи
// по схеме импорта) и `company_settlement` (движения с компанией со сторонами после). Период
// включительно по дате записи, без границы = вся история. Зависимости (доступ, выборки) приходят
// снаружи: index.ts даёт настоящие, тесты подделки.
import {
  ENTRY_COLUMNS,
  entryRecord,
  type ExportEntryRow,
  SETTLEMENT_COLUMNS,
  type SettlementMovementRow,
  settlementRecord,
} from "../_shared/schema.ts";
import { EXPORT_FORMATS, type ExportFormat, zipFiles } from "./format.ts";

export type Period = { from: string | null; to: string | null };

export type Deps = {
  /** Пользователь из заголовка Authorization разрешён (is_allowed, ADR-0007). */
  isAllowed(authorization: string | null): Promise<boolean>;
  /** v_export_entries за период в порядке пересчёта, деньги строкой. */
  loadEntries(authorization: string, period: Period): Promise<ExportEntryRow[]>;
  /** v_settlement_movements за период в порядке пересчёта, деньги строкой. */
  loadMovements(authorization: string, period: Period): Promise<SettlementMovementRow[]>;
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Expose-Headers": "Content-Disposition",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

function isIsoDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(value);
}

/** Имя архива: export_2026-11-01_2026-11-30_csv.zip, без границы «start» или «today». */
export function archiveName(period: Period, format: ExportFormat): string {
  return `export_${period.from ?? "start"}_${period.to ?? "today"}_${format}.zip`;
}

export async function handleExport(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const authorization = req.headers.get("Authorization");
  if (!authorization || !(await deps.isAllowed(authorization))) return json(403, { error: "not_allowed" });

  let body: { from?: unknown; to?: unknown; format?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "field_invalid", field: "payload" });
  }
  const { from = null, to = null, format = "csv" } = body ?? {};
  if (from !== null && !isIsoDate(from)) return json(400, { error: "field_invalid", field: "from" });
  if (to !== null && !isIsoDate(to)) return json(400, { error: "field_invalid", field: "to" });
  if (from !== null && to !== null && from > to) return json(400, { error: "period_invalid" });
  if (!EXPORT_FORMATS.includes(format as ExportFormat)) return json(400, { error: "field_invalid", field: "format" });

  const period: Period = { from: from as string | null, to: to as string | null };
  const [entries, movements] = await Promise.all([
    deps.loadEntries(authorization, period),
    deps.loadMovements(authorization, period),
  ]);
  const zip = await zipFiles(format as ExportFormat, [
    { name: "expenses", columns: ENTRY_COLUMNS, records: entries.map(entryRecord) },
    { name: "company_settlement", columns: SETTLEMENT_COLUMNS, records: movements.map(settlementRecord) },
  ]);
  return new Response(zip as Uint8Array<ArrayBuffer>, {
    status: 200,
    headers: {
      ...CORS,
      "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename="${archiveName(period, format as ExportFormat)}"`,
    },
  });
}
