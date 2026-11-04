import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { amountSign, ENTRY_COLUMNS, entryRecord, type ExportEntryRow, minorToMajor, trimRate } from "./schema.ts";

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
