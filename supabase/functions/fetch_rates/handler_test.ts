import { assertEquals } from "jsr:@std/assert@1";
import { type Deps, handleFetchRates, type RateRow } from "./handler.ts";

const FEED = `<?xml version="1.0" encoding="utf-8"?>
<rates>
    <date>02.11.2026</date>
    <item><title>USD</title><description>480.00</description><quant>1</quant></item>
    <item><title>TRY</title><description>9.08</description><quant>1</quant></item>
</rates>`;

/** Подделки зависимостей: кэш в памяти, источник отдаёт заданный ответ и считает запросы. */
function fakes(overrides: Partial<Deps> = {}) {
  const cache = new Map<string, string>();
  const asked: string[] = [];
  const deps: Deps = {
    isAllowed: (auth) => Promise.resolve(auth === "Bearer owner"),
    readCached: (date, currency) => Promise.resolve(cache.get(`${date} ${currency}`) ?? null),
    storeRates: (rows: RateRow[]) => {
      for (const row of rows) cache.set(`${row.rate_date} ${row.currency}`, row.rate);
      return Promise.resolve();
    },
    fetchNbkXml: (date) => {
      asked.push(date);
      return Promise.resolve(FEED);
    },
    ...overrides,
  };
  return { deps, cache, asked };
}

function post(body: unknown, auth = "Bearer owner"): Request {
  return new Request("http://localhost/fetch_rates", {
    method: "POST",
    headers: { Authorization: auth, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function call(req: Request, deps: Deps) {
  const res = await handleFetchRates(req, deps);
  return { status: res.status, body: await res.json() };
}

Deno.test("fetches the National Bank rate for the date, caches every rate of that date", async () => {
  const { deps, cache, asked } = fakes();
  assertEquals(await call(post({ date: "2026-11-02", currency: "USD" }), deps), {
    status: 200,
    body: { rate_date: "2026-11-02", currency: "USD", rate: "480", source: "nbk", cached: false },
  });
  assertEquals(asked, ["02.11.2026"]);
  assertEquals(cache.get("2026-11-02 TRY"), "9.08");
});

Deno.test("a cached rate is answered from the database without asking the source", async () => {
  const { deps, asked } = fakes();
  await call(post({ date: "2026-11-02", currency: "USD" }), deps);
  assertEquals(await call(post({ date: "2026-11-02", currency: "TRY" }), deps), {
    status: 200,
    body: { rate_date: "2026-11-02", currency: "TRY", rate: "9.08", source: "nbk", cached: true },
  });
  assertEquals(asked.length, 1);
});

Deno.test("the source is unavailable: an error, so the form offers a manual rate or a tenge amount", async () => {
  const { deps, cache } = fakes({ fetchNbkXml: () => Promise.reject(new Error("timeout")) });
  assertEquals(await call(post({ date: "2026-11-02", currency: "USD" }), deps), {
    status: 502,
    body: { error: "fx_source_unavailable" },
  });
  assertEquals(cache.size, 0);
});

Deno.test("an answer that is not the rates feed counts as the source unavailable", async () => {
  const { deps } = fakes({ fetchNbkXml: () => Promise.resolve(`{"code":500}`) });
  assertEquals((await call(post({ date: "2026-11-02", currency: "USD" }), deps)).body, {
    error: "fx_source_unavailable",
  });
});

Deno.test("no rate of this currency on the date: fx_rate_not_found", async () => {
  const { deps } = fakes();
  assertEquals(await call(post({ date: "2026-11-02", currency: "GBP" }), deps), {
    status: 404,
    body: { error: "fx_rate_not_found" },
  });
});

Deno.test("only an allowed user may ask", async () => {
  const { deps, asked } = fakes();
  assertEquals(await call(post({ date: "2026-11-02", currency: "USD" }, "Bearer stranger"), deps), {
    status: 403,
    body: { error: "not_allowed" },
  });
  assertEquals(asked.length, 0);
});

Deno.test("the date and the currency are checked", async () => {
  const { deps } = fakes();
  assertEquals(await call(post({ date: "02.11.2026", currency: "USD" }), deps), {
    status: 400,
    body: { error: "field_invalid", field: "date" },
  });
  assertEquals(await call(post({ date: "2026-11-02", currency: "usd" }), deps), {
    status: 400,
    body: { error: "field_invalid", field: "currency" },
  });
  assertEquals(await call(post({ date: "2026-11-02", currency: "KZT" }), deps), {
    status: 400,
    body: { error: "field_invalid", field: "currency" },
  });
});

Deno.test("the browser preflight gets CORS headers", async () => {
  const res = await handleFetchRates(new Request("http://localhost/fetch_rates", { method: "OPTIONS" }), fakes().deps);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  await res.body?.cancel();
});
