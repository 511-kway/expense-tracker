import { describe, expect, it } from "vitest";
import { defaultExcluded, fileErrorText, nbkRatePairs, rowAmount, rowErrorText, type PreviewRow } from "./importPreview";

const row = (p: Partial<PreviewRow>): PreviewRow => ({
  line: 2,
  status: "create",
  errors: [],
  duplicates: [],
  entry_id: null,
  type: "expense",
  occurred_on: "2026-11-02",
  account: "Kaspi Gold",
  to_account: null,
  category: "Еда",
  title: null,
  amount_minor: "150000",
  currency: "KZT",
  adjustment_sign: null,
  external_id: "e-1",
  ...p,
});

describe("nbkRatePairs", () => {
  it("asks the National Bank rate once per date and currency of rows that use it", () => {
    const rows = [
      { occurred_on: "2026-11-02", currency: "USD", rate_source: "nbk" },
      { occurred_on: "2026-11-02", currency: "USD", rate_source: "nbk" },
      { occurred_on: "2026-11-03", currency: "USD", rate_source: "manual" },
      { occurred_on: "2026-11-03", currency: "EUR", rate_source: "nbk" },
      { occurred_on: "2026-11-03", currency: "KZT", rate_source: "nbk" },
      { occurred_on: null, currency: "EUR", rate_source: "nbk" },
    ];
    expect(nbkRatePairs(rows)).toEqual([
      { date: "2026-11-02", currency: "USD" },
      { date: "2026-11-03", currency: "EUR" },
    ]);
  });
});

describe("rowErrorText", () => {
  it("names the column in the owner's words and says what is wrong", () => {
    expect(rowErrorText({ code: "account_not_found", field: "account", details: { name: "Нет такого" } })).toBe(
      "Счёт «Нет такого» не найден: названия счетов сопоставляются точно",
    );
    expect(rowErrorText({ code: "amount_too_precise", field: "amount" })).toBe(
      "Сумма: больше двух знаков после точки",
    );
    expect(rowErrorText({ code: "amount_sign_invalid", field: "amount", expected: "-" })).toBe(
      "Сумма: у этого типа записи сумма со знаком минус",
    );
    expect(rowErrorText({ code: "missing_required", field: "category" })).toBe("Категория: заполните поле");
    expect(rowErrorText({ code: "advance_return_too_big", field: null })).toBe(
      "Изъять можно не больше аванса на счёте на эту дату",
    );
  });
});

describe("rowAmount", () => {
  it("formats the amount of the row; the server sends minor units as a string", () => {
    expect(rowAmount(row({}))).toBe("1\u00a0500\u00a0₸");
    expect(rowAmount(row({ amount_minor: "1050", currency: "USD" }))).toBe("$10,50");
    expect(rowAmount(row({ amount_minor: null }))).toBe("");
  });
});

describe("defaultExcluded", () => {
  it("leaves out possible duplicates unless the owner keeps them", () => {
    expect(
      defaultExcluded([
        row({ line: 2 }),
        row({ line: 3, duplicates: [{ entry_id: "x", occurred_on: "2026-11-02" }] }),
        row({ line: 4, status: "error", duplicates: [{ entry_id: "x", occurred_on: "2026-11-02" }] }),
      ]),
    ).toEqual([3]);
  });
});

describe("fileErrorText", () => {
  it("explains what is wrong with the file as a whole", () => {
    expect(fileErrorText({ code: "columns_missing", columns: ["occurred_on", "amount"] })).toBe(
      "В файле нет колонок occurred_on, amount. Скачайте шаблон: в нём все колонки.",
    );
    expect(fileErrorText({ code: "format_unsupported" })).toBe("Загрузите файл CSV, Excel (xlsx), JSON или архив экспорта (zip).");
  });
});
