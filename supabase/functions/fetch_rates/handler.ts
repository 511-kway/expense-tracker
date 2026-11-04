// fetch_rates(date, currency) → { rate } (док 05): курс Нацбанка РК на дату. Если курс уже в кэше
// fx_rates, отдаёт его, иначе тянет курсы на эту дату, кладёт все в кэш и отдаёт нужный. Источник
// недоступен: ошибка fx_source_unavailable, форма предлагает свой курс или сумму в тенге.
// Зависимости (доступ, кэш, HTTP к Нацбанку) приходят снаружи: index.ts даёт настоящие, тесты подделки.
import { nbkDate, parseNbkRates } from "./nbk.ts";

export type RateRow = { rate_date: string; currency: string; rate: string };

export type Deps = {
  /** Пользователь из заголовка Authorization разрешён (is_allowed, ADR-0007). */
  isAllowed(authorization: string | null): Promise<boolean>;
  /** Курс из fx_rates строкой или null. */
  readCached(date: string, currency: string): Promise<string | null>;
  storeRates(rows: RateRow[]): Promise<void>;
  /** XML курсов на дату DD.MM.YYYY; при сетевой ошибке или не-200 бросает исключение. */
  fetchNbkXml(nbkDate: string): Promise<string>;
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

function isIsoDate(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(value);
}

export async function handleFetchRates(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  if (!(await deps.isAllowed(req.headers.get("Authorization")))) return json(403, { error: "not_allowed" });

  let body: { date?: unknown; currency?: unknown };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "field_invalid", field: "payload" });
  }
  const { date, currency } = body ?? {};
  if (!isIsoDate(date)) return json(400, { error: "field_invalid", field: "date" });
  if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency) || currency === "KZT") {
    return json(400, { error: "field_invalid", field: "currency" });
  }

  const cached = await deps.readCached(date, currency);
  if (cached !== null) return json(200, { rate_date: date, currency, rate: cached, source: "nbk", cached: true });

  let rates;
  try {
    rates = parseNbkRates(await deps.fetchNbkXml(nbkDate(date)));
  } catch (error) {
    console.error("fetch_rates: National Bank source unavailable", error);
    return json(502, { error: "fx_source_unavailable" });
  }
  if (rates.length > 0) {
    await deps.storeRates(rates.map((r) => ({ rate_date: date, currency: r.currency, rate: r.rate })));
  }
  const found = rates.find((r) => r.currency === currency);
  if (!found) return json(404, { error: "fx_rate_not_found" });
  return json(200, { rate_date: date, currency, rate: found.rate, source: "nbk", cached: false });
}
