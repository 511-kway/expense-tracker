import { assertEquals } from "jsr:@std/assert@1";
import { strFromU8, unzipSync } from "npm:fflate@0.8.2";
import type { ExportEntryRow, SettlementMovementRow } from "../_shared/schema.ts";
import { type Deps, handleExport, type Period } from "./handler.ts";

const expense: ExportEntryRow = {
  occurred_on: "2026-11-02",
  type: "expense",
  account_name: "Kaspi Gold",
  amount_minor: "150000",
  currency: "KZT",
  category_name: "Реклама",
  source: null,
  purpose: "work",
  transfer_purpose: null,
  to_account_name: null,
  fee_minor: "0",
  fee_payer: null,
  comment: null,
  title: "Таргет",
  external_id: "e-1",
  settlement_direction: null,
  adjustment_target: null,
  adjustment_mode: null,
  adjustment_sign: null,
  adjustment_affects_advance: false,
  parent_external_id: null,
  rate: null,
  rate_source: null,
  amount_kzt_minor: "150000",
  in_analytics: true,
};

const movement: SettlementMovementRow = {
  occurred_on: "2026-11-02",
  type: "expense",
  account_name: "Kaspi Gold",
  to_account_name: null,
  title: "Таргет",
  parent_title: null,
  category_name: "Реклама",
  purpose: "work",
  source: null,
  transfer_purpose: null,
  settlement_direction: null,
  currency: "KZT",
  company_owes_me_delta_minor: "150000",
  i_owe_company_delta_minor: "0",
  company_owes_me_after_minor: "650000",
  i_owe_company_after_minor: "300000",
  net_after_minor: "350000",
  external_id: "e-1",
};

function fakes() {
  const periods: Period[] = [];
  const deps: Deps = {
    isAllowed: (auth) => Promise.resolve(auth === "Bearer owner"),
    loadEntries: (_auth, period) => {
      periods.push(period);
      return Promise.resolve([expense]);
    },
    loadMovements: () => Promise.resolve([movement]),
  };
  return { deps, periods };
}

function post(body: unknown, auth = "Bearer owner"): Request {
  return new Request("http://localhost/export", {
    method: "POST",
    headers: { Authorization: auth, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

Deno.test("CSV export for a period: a zip with expenses and company_settlement", async () => {
  const { deps, periods } = fakes();
  const res = await handleExport(post({ from: "2026-11-01", to: "2026-11-30", format: "csv" }), deps);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Content-Type"), "application/zip");
  assertEquals(
    res.headers.get("Content-Disposition"),
    'attachment; filename="export_2026-11-01_2026-11-30_csv.zip"',
  );
  assertEquals(periods, [{ from: "2026-11-01", to: "2026-11-30" }]);

  const files = unzipSync(new Uint8Array(await res.arrayBuffer()));
  assertEquals(Object.keys(files).sort(), ["company_settlement.csv", "expenses.csv"]);
  const [header, row] = strFromU8(files["expenses.csv"]!).replace("﻿", "").split("\r\n");
  assertEquals(
    header,
    "occurred_on,type,account,amount,currency,category,source,purpose,transfer_purpose,to_account,fee,fee_payer," +
      "comment,title,external_id,settlement_direction,adjustment_target,adjustment_mode,adjustment_affects_advance," +
      "parent_external_id,rate,rate_source,amount_kzt,in_analytics",
  );
  assertEquals(row, "2026-11-02,expense,Kaspi Gold,-1500.00,KZT,Реклама,,work,,,,,,Таргет,e-1,,,,,,,,-1500.00,true");

  const settlement = strFromU8(files["company_settlement.csv"]!).replace("﻿", "").split("\r\n");
  assertEquals(
    settlement[0],
    "occurred_on,type,account,to_account,title,category,purpose,source,transfer_purpose,settlement_direction,currency," +
      "company_owes_me_change,i_owe_company_change,company_owes_me_after,i_owe_company_after,net_after,external_id",
  );
  assertEquals(
    settlement[1],
    "2026-11-02,expense,Kaspi Gold,,Таргет,Реклама,work,,,,KZT,1500.00,0.00,6500.00,3000.00,3500.00,e-1",
  );
});

Deno.test("xlsx and JSON exports name the files by format; no period means the whole history", async () => {
  const { deps, periods } = fakes();
  for (const format of ["xlsx", "json"]) {
    const res = await handleExport(post({ format }), deps);
    assertEquals(res.headers.get("Content-Disposition"), `attachment; filename="export_start_today_${format}.zip"`);
    const files = unzipSync(new Uint8Array(await res.arrayBuffer()));
    assertEquals(Object.keys(files).sort(), [`company_settlement.${format}`, `expenses.${format}`]);
  }
  assertEquals(periods, [{ from: null, to: null }, { from: null, to: null }]);
});

Deno.test("the period and the format are checked", async () => {
  const { deps } = fakes();
  const call = async (body: unknown) => {
    const res = await handleExport(post(body), deps);
    return { status: res.status, body: await res.json() };
  };
  assertEquals(await call({ from: "01.11.2026" }), { status: 400, body: { error: "field_invalid", field: "from" } });
  assertEquals(await call({ to: "2026-02-30" }), { status: 400, body: { error: "field_invalid", field: "to" } });
  assertEquals(await call({ from: "2026-11-30", to: "2026-11-01" }), {
    status: 400,
    body: { error: "period_invalid" },
  });
  assertEquals(await call({ format: "pdf" }), { status: 400, body: { error: "field_invalid", field: "format" } });
});

Deno.test("only an allowed user may export", async () => {
  const { deps, periods } = fakes();
  const res = await handleExport(post({ format: "csv" }, "Bearer stranger"), deps);
  assertEquals([res.status, await res.json()], [403, { error: "not_allowed" }]);
  assertEquals(periods, []);
});

Deno.test("the browser preflight gets CORS headers and may read the file name", async () => {
  const res = await handleExport(new Request("http://localhost/export", { method: "OPTIONS" }), fakes().deps);
  assertEquals(res.headers.get("Access-Control-Expose-Headers"), "Content-Disposition");
  await res.body?.cancel();
});
