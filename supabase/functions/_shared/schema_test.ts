import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  amountSign,
  ENTRY_COLUMNS,
  entryRecord,
  type ExportEntryRow,
  importRow,
  minorToMajor,
  parseMoney,
  trimRate,
} from "./schema.ts";

Deno.test("the expenses file starts with the import schema of doc 04, section 8", () => {
  assertEquals(ENTRY_COLUMNS.slice(0, 15).map((c) => c.name), [
    "occurred_on",
    "type",
    "account",
    "amount",
    "currency",
    "category",
    "source",
    "purpose",
    "transfer_purpose",
    "to_account",
    "fee",
    "fee_payer",
    "comment",
    "title",
    "external_id",
  ]);
});

Deno.test("minor units become major units with exactly two digits, no separators, no float", () => {
  assertEquals(minorToMajor("150000000"), "1500000.00");
  assertEquals(minorToMajor("150000"), "1500.00");
  assertEquals(minorToMajor("-150000"), "-1500.00");
  assertEquals(minorToMajor("150050"), "1500.50");
  assertEquals(minorToMajor("5"), "0.05");
  assertEquals(minorToMajor("-5"), "-0.05");
  assertEquals(minorToMajor("0"), "0.00");
  assertEquals(minorToMajor("-0"), "0.00");
  // Больше 2^53: через float последние знаки потерялись бы.
  assertEquals(minorToMajor("9007199254740993"), "90071992547409.93");
  assertEquals(minorToMajor(1234n), "12.34");
  assertThrows(() => minorToMajor("15.5"));
});

Deno.test("a rate loses trailing zeros", () => {
  assertEquals(trimRate("480.00000000"), "480");
  assertEquals(trimRate("453.64000000"), "453.64");
  assertEquals(trimRate("0.00587333"), "0.00587333");
});

Deno.test("sign of the amount: money leaving the account is negative", () => {
  const sign = (type: string, extra = {}) => amountSign({ type, ...extra });
  assertEquals(sign("expense"), -1);
  assertEquals(sign("transfer"), -1);
  assertEquals(sign("company_advance_return"), -1);
  assertEquals(sign("settlement", { settlement_direction: "i_paid_company" }), -1);
  assertEquals(sign("income"), 1);
  assertEquals(sign("company_topup"), 1);
  assertEquals(sign("refund"), 1);
  assertEquals(sign("settlement", { settlement_direction: "company_paid_me" }), 1);
  assertEquals(sign("netting"), 1);
  assertEquals(sign("adjustment", { adjustment_sign: -1 }), -1);
  assertEquals(sign("adjustment", { adjustment_sign: 1 }), 1);
});

const base: ExportEntryRow = {
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

Deno.test("an expense: negative amount and tenge equivalent, no fee, names of account and category", () => {
  const r = entryRecord(base);
  assertEquals(r.amount, { money: "-1500.00" });
  assertEquals(r.amount_kzt, { money: "-1500.00" });
  assertEquals(r.fee, null);
  assertEquals([r.occurred_on, r.account, r.category, r.purpose], ["2026-11-02", "Kaspi Gold", "Реклама", "work"]);
  assertEquals(r.adjustment_affects_advance, null);
  assertEquals(r.in_analytics, true);
});

Deno.test("a transfer with a fee: the fee is a charge, negative", () => {
  const r = entryRecord({
    ...base,
    type: "transfer",
    category_name: null,
    purpose: null,
    transfer_purpose: "move_own",
    to_account_name: "Halyk",
    fee_minor: "100000",
    fee_payer: "own",
    amount_minor: "50000000",
    amount_kzt_minor: "50000000",
  });
  assertEquals([r.amount, r.fee, r.fee_payer, r.to_account], [
    { money: "-500000.00" },
    { money: "-1000.00" },
    "own",
    "Halyk",
  ]);
});

Deno.test("a dollar expense keeps its currency, the rate and the tenge equivalent", () => {
  const r = entryRecord({
    ...base,
    amount_minor: "1050",
    currency: "USD",
    rate: "480.00000000",
    rate_source: "nbk",
    amount_kzt_minor: "504000",
  });
  assertEquals([r.amount, r.currency, r.rate, r.rate_source, r.amount_kzt], [
    { money: "-10.50" },
    "USD",
    "480",
    "nbk",
    { money: "-5040.00" },
  ]);
});

Deno.test("an adjustment of the balance carries its sign and whether it is company money", () => {
  const r = entryRecord({
    ...base,
    type: "adjustment",
    category_name: null,
    purpose: null,
    adjustment_target: "balance",
    adjustment_mode: "plug_hidden",
    adjustment_sign: -1,
    adjustment_affects_advance: true,
    in_analytics: false,
  });
  assertEquals([r.amount, r.adjustment_target, r.adjustment_affects_advance, r.in_analytics], [
    { money: "-1500.00" },
    "balance",
    true,
    false,
  ]);
});

Deno.test("a refund is positive and points to its expense", () => {
  const r = entryRecord({ ...base, type: "refund", parent_external_id: "e-0" });
  assertEquals([r.amount, r.parent_external_id], [{ money: "1500.00" }, "e-0"]);
});

// Импорт (тикет 18): сумма из файла строкой в целые минимальные единицы со знаком, без float.

Deno.test("an amount from a file becomes signed minor units: -1500.00 and (1500.00) are both negative", () => {
  assertEquals(parseMoney("1500000.00"), { minor: "150000000" });
  assertEquals(parseMoney("-1500.00"), { minor: "-150000" });
  assertEquals(parseMoney("(1500.00)"), { minor: "-150000" });
  assertEquals(parseMoney("1500"), { minor: "150000" });
  assertEquals(parseMoney("1500.5"), { minor: "150050" });
  assertEquals(parseMoney(" 0.07 "), { minor: "7" });
  assertEquals(parseMoney("+12.30"), { minor: "1230" });
  assertEquals(parseMoney("-0.00"), { minor: "0" });
  assertEquals(parseMoney(".5"), { minor: "50" });
  // Больше 2^53: через float последние знаки потерялись бы.
  assertEquals(parseMoney("90071992547409.93"), { minor: "9007199254740993" });
});

Deno.test("more than two decimals is a row error, so is anything that is not a plain number", () => {
  assertEquals(parseMoney("1500.001"), { error: "amount_too_precise" });
  assertEquals(parseMoney("(0.125)"), { error: "amount_too_precise" });
  for (const bad of ["1,500.00", "1 500.00", "1500,00", "abc", "", "-(15.00)", "(15.00", "1e3", "--1", "."]) {
    assertEquals(parseMoney(bad), { error: "amount_invalid" }, bad);
  }
});

/** Строка файла так, как её отдают читатели CSV, JSON и xlsx: текст, логическое или пусто. */
function fileRow(cells: Record<string, string | boolean | null>) {
  return importRow(7, { occurred_on: "2026-11-02", currency: "KZT", ...cells });
}

Deno.test("an imported expense: the sign of the amount must be minus, the amount becomes positive minor units", () => {
  const row = fileRow({
    type: "expense",
    account: " Kaspi Gold ",
    amount: "-1500.00",
    category: "Реклама",
    purpose: "work",
  });
  assertEquals(row.errors, []);
  assertEquals([row.line, row.type, row.account, row.amount_minor, row.category, row.purpose, row.comment], [
    7,
    "expense",
    "Kaspi Gold",
    "150000",
    "Реклама",
    "work",
    null,
  ]);
  assertEquals(fileRow({ type: "expense", amount: "(1500.00)" }).amount_minor, "150000");
  assertEquals(fileRow({ type: "expense", amount: "1500.00" }).errors, [
    { field: "amount", code: "amount_sign_invalid", expected: "-" },
  ]);
  assertEquals(fileRow({ type: "income", amount: "-1.00" }).errors, [
    { field: "amount", code: "amount_sign_invalid", expected: "+" },
  ]);
});

Deno.test("an imported adjustment takes its sign from the amount; a settlement's sign follows its direction", () => {
  const minus = fileRow({
    type: "adjustment",
    amount: "-50.00",
    adjustment_target: "balance",
    adjustment_affects_advance: "TRUE",
  });
  assertEquals([minus.amount_minor, minus.adjustment_sign, minus.adjustment_affects_advance, minus.errors], [
    "5000",
    -1,
    true,
    [],
  ]);
  assertEquals(fileRow({ type: "adjustment", amount: "50.00" }).adjustment_sign, 1);
  assertEquals(fileRow({ type: "settlement", settlement_direction: "i_paid_company", amount: "-5.00" }).errors, []);
  assertEquals(fileRow({ type: "settlement", settlement_direction: "company_paid_me", amount: "5.00" }).errors, []);
  assertEquals(fileRow({ type: "settlement", settlement_direction: "company_paid_me", amount: "-5.00" }).errors, [
    { field: "amount", code: "amount_sign_invalid", expected: "+" },
  ]);
  assertEquals(fileRow({ type: "netting", amount: "5.00" }).adjustment_sign, null);
});

Deno.test("an imported fee is a charge (minus), the tenge equivalent has the sign of the amount", () => {
  const row = fileRow({
    type: "transfer",
    amount: "-5000.00",
    fee: "-10.00",
    fee_payer: "own",
    amount_kzt: "-5000.00",
  });
  assertEquals([row.fee_minor, row.amount_kzt_minor, row.errors], ["1000", "500000", []]);
  assertEquals(fileRow({ type: "transfer", amount: "-5000.00", fee: "10.00" }).errors, [
    { field: "fee", code: "amount_sign_invalid", expected: "-" },
  ]);
  assertEquals(fileRow({ type: "expense", amount: "-10.50", amount_kzt: "5040.00" }).errors, [
    { field: "amount_kzt", code: "amount_sign_invalid", expected: "-" },
  ]);
  assertEquals(fileRow({ type: "income", amount: "1.00", fee: null }).fee_minor, null);
});

Deno.test("an imported row reports every bad cell: amount format, date, type, boolean, rate", () => {
  assertEquals(fileRow({ type: "expense", amount: "-1500.005" }).errors, [{
    field: "amount",
    code: "amount_too_precise",
  }]);
  assertEquals(fileRow({ type: "expense", amount: "1 500" }).errors, [{ field: "amount", code: "amount_invalid" }]);
  assertEquals(fileRow({ type: "expense", amount: null }).errors, [{ field: "amount", code: "missing_required" }]);
  assertEquals(fileRow({ type: "expense", amount: "-1.00", occurred_on: "02.11.2026" }).errors, [
    { field: "occurred_on", code: "field_invalid" },
  ]);
  assertEquals(fileRow({ type: "expense", amount: "-1.00", occurred_on: "2026-02-30" }).errors, [
    { field: "occurred_on", code: "field_invalid" },
  ]);
  assertEquals(fileRow({ type: "purchase", amount: "-1.00" }).errors, [{ field: "type", code: "field_invalid" }]);
  assertEquals(fileRow({ type: null, amount: "-1.00" }).errors, [{ field: "type", code: "missing_required" }]);
  assertEquals(fileRow({ type: "expense", amount: "-1.00", in_analytics: "да" }).errors, [
    { field: "in_analytics", code: "field_invalid" },
  ]);
  assertEquals(fileRow({ type: "expense", amount: "-1.00", rate: "480,5" }).errors, [
    { field: "rate", code: "field_invalid" },
  ]);
  const ok = fileRow({ type: "expense", amount: "-1.00", rate: "480.015", in_analytics: false });
  assertEquals([ok.rate, ok.in_analytics, ok.errors], ["480.015", false, []]);
});

Deno.test("an exported entry read back is the same entry: export and import share one schema", () => {
  const rows: ExportEntryRow[] = [
    base,
    { ...base, type: "refund", parent_external_id: "e-0", external_id: "e-2" },
    {
      ...base,
      type: "transfer",
      category_name: null,
      purpose: null,
      transfer_purpose: "move_own",
      to_account_name: "Halyk",
      fee_minor: "100000",
      fee_payer: "own",
    },
    {
      ...base,
      type: "adjustment",
      category_name: null,
      purpose: null,
      adjustment_target: "balance",
      adjustment_mode: "plug_hidden",
      adjustment_sign: -1,
      adjustment_affects_advance: true,
      in_analytics: false,
    },
    {
      ...base,
      amount_minor: "1050",
      currency: "USD",
      rate: "480.00000000",
      rate_source: "nbk",
      amount_kzt_minor: "504000",
    },
  ];
  for (const row of rows) {
    const record = entryRecord(row);
    const cells = Object.fromEntries(
      Object.entries(record).map(([k, v]) => [k, v !== null && typeof v === "object" ? v.money : v]),
    );
    const back = importRow(2, cells);
    assertEquals(back.errors, [], row.type);
    assertEquals(back.amount_minor, row.amount_minor);
    assertEquals(back.amount_kzt_minor, row.amount_kzt_minor);
    assertEquals(back.fee_minor, row.fee_minor === "0" ? null : row.fee_minor);
    assertEquals(back.adjustment_sign, row.adjustment_sign);
    assertEquals(back.parent_external_id, row.parent_external_id);
    assertEquals(back.account, row.account_name);
  }
});
