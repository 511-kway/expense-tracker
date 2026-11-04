// Edge Function fetch_rates: настоящие зависимости для handler.ts. Доступ проверяет is_allowed()
// с JWT пользователя; кэш fx_rates читается и пишется ключом service_role (клиенту таблица
// только на чтение). Курс читается из базы текстом (rate::text), чтобы не проходить через float.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { type Deps, handleFetchRates } from "./handler.ts";

const NBK_URL = "https://nationalbank.kz/rss/get_rates.cfm";
const NBK_TIMEOUT_MS = 10_000;

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const service = createClient(url, serviceKey, { auth: { persistSession: false } });

const deps: Deps = {
  async isAllowed(authorization) {
    if (!authorization) return false;
    const user = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authorization } },
    });
    const { data, error } = await user.rpc("is_allowed");
    return !error && data === true;
  },
  async readCached(date, currency) {
    const { data, error } = await service.from("fx_rates").select("rate::text")
      .eq("rate_date", date).eq("currency", currency).maybeSingle();
    if (error) throw error;
    const rate = (data as { rate: string } | null)?.rate;
    return rate === undefined ? null : rate.replace(/\.?0+$/, ""); // "480.00000000" → "480"
  },
  async storeRates(rows) {
    const { error } = await service.from("fx_rates")
      .upsert(rows, { onConflict: "rate_date,currency", ignoreDuplicates: true });
    if (error) throw error;
  },
  async fetchNbkXml(nbkDate) {
    const res = await fetch(`${NBK_URL}?fdate=${encodeURIComponent(nbkDate)}`, {
      signal: AbortSignal.timeout(NBK_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`National Bank answered ${res.status}`);
    return await res.text();
  },
};

Deno.serve((req) => handleFetchRates(req, deps));
