import { assertEquals } from "jsr:@std/assert@1";
import { strFromU8, strToU8, unzipSync, zipSync } from "npm:fflate@0.8.2";
import { ENTRY_COLUMNS, entryRecord, type ExportEntryRow, type ImportRow } from "../_shared/schema.ts";
import { toCsv, toJson, toXlsx } from "../export/format.ts";
import { excelNumber, parseImportFile } from "./parse.ts";

const HEADER = "occurred_on,type,account,amount,currency,category,purpose,title,external_id";

function csv(...lines: string[]): Uint8Array {
  return strToU8([HEADER, ...lines].join("\r\n") + "\r\n");
}

Deno.test("CSV: rows with sheet line numbers, -1500.00 and (1500.00) both negative, quoted text", async () => {
  const result = await parseImportFile(
    "expenses.csv",
    csv(
      '2026-11-02,expense,Kaspi Gold,-1500.00,KZT,Реклама,work,"Таргет, ноябрь",e-1',
      "2026-11-03,expense,Kaspi Gold,(1500.00),KZT,Реклама,personal,,e-2",
    ),
  );
  assertEquals(result.format, "csv");
  assertEquals(result.errors, []);
  assertEquals(result.rows.map((r) => [r.line, r.amount_minor, r.title, r.external_id, r.errors]), [
    [2, "150000", "Таргет, ноябрь", "e-1", []],
    [3, "150000", null, "e-2", []],
  ]);
});

Deno.test("CSV: more than two decimals is an error of that row only; BOM and empty lines are skipped", async () => {
  const bytes = strToU8(
    "﻿" + HEADER + "\n" +
      "2026-11-02,expense,Kaspi Gold,-1500.005,KZT,Реклама,work,,e-1\n" +
      "\n" +
      "2026-11-04,income,Kaspi Gold,10.00,KZT,,,,e-3\n",
  );
  const result = await parseImportFile("my.csv", bytes);
  assertEquals(result.rows.map((r) => [r.line, r.errors]), [
    [2, [{ field: "amount", code: "amount_too_precise" }]],
    [4, []],
  ]);
});

Deno.test("a file without a required column or with an unknown one is rejected as a whole", async () => {
  const missing = await parseImportFile("x.csv", strToU8("occurred_on,type\n2026-11-02,expense\n"));
  assertEquals(missing.errors, [{ code: "columns_missing", columns: ["amount"] }]);
  assertEquals(missing.rows, []);
  const unknown = await parseImportFile("x.csv", strToU8("occurred_on,type,amount,sum\n2026-11-02,expense,-1.00,1\n"));
  assertEquals(unknown.errors, [{ code: "columns_unknown", columns: ["sum"] }]);
  assertEquals((await parseImportFile("x.csv", strToU8(HEADER + "\n"))).errors, [{ code: "file_empty" }]);
  assertEquals((await parseImportFile("x.txt", strToU8("hi"))).errors, [{ code: "format_unsupported" }]);
});

Deno.test("JSON: amounts are read from the number text, not through float", async () => {
  const text = `[
    {"occurred_on": "2026-11-02", "type": "expense", "account": "Kaspi Gold", "amount": -1500.10, "category": "Реклама", "purpose": "work"},
    {"occurred_on": "2026-11-02", "type": "income", "account": "Kaspi Gold", "amount": 90071992547409.93, "in_analytics": true},
    {"occurred_on": "2026-11-02", "type": "expense", "account": "Kaspi Gold", "amount": "(0.30)", "comment": null},
    {"occurred_on": "2026-11-02", "type": "expense", "account": "Kaspi Gold", "amount": -0.105}
  ]`;
  const result = await parseImportFile("expenses.json", strToU8(text));
  assertEquals(result.errors, []);
  assertEquals(result.rows.map((r) => [r.line, r.amount_minor, r.in_analytics, r.errors.map((e) => e.code)]), [
    [1, "150010", null, []],
    [2, "9007199254740993", true, []],
    [3, "30", null, []],
    [4, null, null, ["amount_too_precise"]],
  ]);
  assertEquals((await parseImportFile("x.json", strToU8('{"a": 1}'))).errors, [{ code: "file_invalid" }]);
  assertEquals((await parseImportFile("x.json", strToU8("[1, 2"))).errors, [{ code: "file_invalid" }]);
});

Deno.test("an Excel number is read as Excel shows it, 15 significant digits, without float drift", () => {
  assertEquals(excelNumber("1234.5599999999999"), "1234.56");
  assertEquals(excelNumber("0.30000000000000004"), "0.3");
  assertEquals(excelNumber("-1500.0999999999999"), "-1500.1");
  assertEquals(excelNumber("-1500.1"), "-1500.1");
  assertEquals(excelNumber("1500"), "1500");
  assertEquals(excelNumber("1E-3"), "0.001");
  assertEquals(excelNumber("1.5E+3"), "1500");
  assertEquals(excelNumber("1500.123"), "1500.123");
  assertEquals(excelNumber("9999999999999.99"), "9999999999999.99");
});

/** Подменяет текст числовой ячейки в листе xlsx: так файл выглядит после Excel с дрейфом float. */
function withSheetValue(xlsx: Uint8Array, from: string, to: string): Uint8Array {
  const files = unzipSync(xlsx);
  const sheet = strFromU8(files["xl/worksheets/sheet1.xml"]!);
  assertEquals(sheet.includes(`<v>${from}</v>`), true);
  files["xl/worksheets/sheet1.xml"] = strToU8(sheet.replace(`<v>${from}</v>`, `<v>${to}</v>`));
  return zipSync(files);
}

const exported: ExportEntryRow[] = [
  {
    occurred_on: "2026-11-02",
    type: "expense",
    account_name: "Kaspi Gold",
    amount_minor: "123456",
    currency: "KZT",
    category_name: "Реклама",
    source: null,
    purpose: "work",
    transfer_purpose: null,
    to_account_name: null,
    fee_minor: "0",
    fee_payer: null,
    comment: "Обед, с «Алиной»",
    title: "Таргет",
    external_id: "11111111-1111-1111-1111-111111111111",
    settlement_direction: null,
    adjustment_target: null,
    adjustment_mode: null,
    adjustment_sign: null,
    adjustment_affects_advance: false,
    parent_external_id: null,
    rate: null,
    rate_source: null,
    amount_kzt_minor: "123456",
    in_analytics: true,
  },
  {
    occurred_on: "2026-11-03",
    type: "transfer",
    account_name: "Kaspi Gold",
    amount_minor: "50000000",
    currency: "KZT",
    category_name: null,
    source: null,
    purpose: null,
    transfer_purpose: "move_own",
    to_account_name: "Halyk",
    fee_minor: "100000",
    fee_payer: "own",
    comment: null,
    title: null,
    external_id: "e-2",
    settlement_direction: null,
    adjustment_target: null,
    adjustment_mode: null,
    adjustment_sign: null,
    adjustment_affects_advance: false,
    parent_external_id: null,
    rate: null,
    rate_source: null,
    amount_kzt_minor: "50000000",
    in_analytics: true,
  },
  {
    occurred_on: "2026-11-04",
    type: "adjustment",
    account_name: "Kaspi Gold",
    amount_minor: "5",
    currency: "KZT",
    category_name: null,
    source: null,
    purpose: null,
    transfer_purpose: null,
    to_account_name: null,
    fee_minor: "0",
    fee_payer: null,
    comment: null,
    title: "Сверка",
    external_id: "e-3",
    settlement_direction: null,
    adjustment_target: "balance",
    adjustment_mode: "plug_hidden",
    adjustment_sign: -1,
    adjustment_affects_advance: true,
    parent_external_id: null,
    rate: null,
    rate_source: null,
    amount_kzt_minor: "5",
    in_analytics: false,
  },
  {
    occurred_on: "2026-11-05",
    type: "refund",
    account_name: "Kaspi Gold",
    amount_minor: "1050",
    currency: "USD",
    category_name: "Реклама",
    source: null,
    purpose: "work",
    transfer_purpose: null,
    to_account_name: null,
    fee_minor: "0",
    fee_payer: null,
    comment: null,
    title: null,
    external_id: "e-4",
    settlement_direction: null,
    adjustment_target: null,
    adjustment_mode: null,
    adjustment_sign: null,
    adjustment_affects_advance: false,
    parent_external_id: "11111111-1111-1111-1111-111111111111",
    rate: "480.01500000",
    rate_source: "manual",
    amount_kzt_minor: "504016",
    in_analytics: true,
  },
];

/** Что импорт должен прочитать из выгрузки этих записей: те же поля, суммы модулем в тиынах. */
const expected: ImportRow[] = exported.map((e, i) => ({
  line: i + 2,
  occurred_on: e.occurred_on,
  type: e.type,
  account: e.account_name,
  amount_minor: e.amount_minor,
  currency: e.currency,
  category: e.category_name,
  source: e.source,
  purpose: e.purpose,
  transfer_purpose: e.transfer_purpose,
  to_account: e.to_account_name,
  fee_minor: e.fee_minor === "0" ? null : e.fee_minor,
  fee_payer: e.fee_payer,
  comment: e.comment,
  title: e.title,
  external_id: e.external_id,
  settlement_direction: e.settlement_direction,
  adjustment_target: e.adjustment_target,
  adjustment_mode: e.adjustment_mode,
  adjustment_sign: e.adjustment_sign as 1 | -1 | null,
  adjustment_affects_advance: e.type === "adjustment" ? e.adjustment_affects_advance : null,
  parent_external_id: e.parent_external_id,
  rate: e.rate === null ? null : e.rate.replace(/0+$/, ""),
  rate_source: e.rate_source,
  amount_kzt_minor: e.amount_kzt_minor,
  in_analytics: e.in_analytics,
  errors: [],
}));

Deno.test("round trip: the expenses file of an export, in CSV, JSON and xlsx, reads back to the same entries", async () => {
  const records = exported.map(entryRecord);
  const files = {
    "expenses.csv": strToU8(toCsv(ENTRY_COLUMNS, records)),
    "expenses.json": strToU8(toJson(ENTRY_COLUMNS, records)),
    "expenses.xlsx": await toXlsx("expenses", ENTRY_COLUMNS, records),
  };
  for (const [name, bytes] of Object.entries(files)) {
    const result = await parseImportFile(name, bytes);
    assertEquals(result.errors, [], name);
    const rows = name.endsWith(".json") ? expected.map((r) => ({ ...r, line: r.line - 1 })) : expected;
    assertEquals(result.rows, rows, name);
  }
});

Deno.test("the export zip itself can be uploaded: its expenses file is read", async () => {
  const records = exported.map(entryRecord);
  const zip = zipSync({
    "expenses.csv": strToU8(toCsv(ENTRY_COLUMNS, records)),
    "company_settlement.csv": strToU8("occurred_on\n"),
  });
  const result = await parseImportFile("export_start_today_csv.zip", zip);
  assertEquals([result.format, result.errors, result.rows.length], ["csv", [], 4]);
  const empty = await parseImportFile("x.zip", zipSync({ "other.csv": strToU8("a\n") }));
  assertEquals(empty.errors, [{ code: "zip_without_expenses" }]);
});

Deno.test("xlsx: a numeric cell with float drift reads as its two-digit amount", async () => {
  const records = [entryRecord(exported[0]!)];
  const xlsx = withSheetValue(await toXlsx("expenses", ENTRY_COLUMNS, records), "-1234.56", "-1234.5599999999999");
  const [row] = (await parseImportFile("expenses.xlsx", xlsx)).rows;
  assertEquals([row!.amount_minor, row!.amount_kzt_minor, row!.errors], ["123456", "123456", []]);
});

Deno.test("xlsx: a date typed as an Excel date is read as ISO", async () => {
  const xlsx = await toXlsx("expenses", ENTRY_COLUMNS.slice(0, 4), [
    { occurred_on: "2026-11-02", type: "expense", account: "Kaspi Gold", amount: { money: "-1.00" } },
  ]);
  // Дата 2026-11-02 в Excel: число 46328 с форматом даты (встроенный numFmtId 14).
  const files = unzipSync(xlsx);
  let sheet = strFromU8(files["xl/worksheets/sheet1.xml"]!);
  sheet = sheet.replace(/<c r="A2"[^>]*?(\/>|>.*?<\/c>)/, '<c r="A2" s="9"><v>46328</v></c>');
  assertEquals(sheet.includes('<c r="A2" s="9"><v>46328</v></c>'), true);
  files["xl/worksheets/sheet1.xml"] = strToU8(sheet);
  let styles = strFromU8(files["xl/styles.xml"]!);
  styles = styles.replace(/<cellXfs count="(\d+)">(.*?)<\/cellXfs>/s, (_m, _n, inner) => {
    const xfs = inner.match(/<xf [^>]*?(\/>|>.*?<\/xf>)/gs) as string[];
    while (xfs.length < 9) xfs.push('<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>');
    xfs.push('<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>');
    return `<cellXfs count="${xfs.length}">${xfs.join("")}</cellXfs>`;
  });
  files["xl/styles.xml"] = strToU8(styles);
  const result = await parseImportFile("expenses.xlsx", zipSync(files));
  assertEquals(result.rows.map((r) => [r.occurred_on, r.amount_minor, r.errors]), [["2026-11-02", "100", []]]);
});
