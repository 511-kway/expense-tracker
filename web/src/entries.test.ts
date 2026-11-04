import { describe, expect, it } from "vitest";
import { advanceReturnErrorText, entryTitle, errorDetails, formatSigned, warningLines } from "./entries";

const names = new Map([["a1", "Kaspi Gold"]]);

describe("warningLines", () => {
  it("tells which account went below zero, when and by how much", () => {
    expect(
      warningLines(
        [{ code: "negative_balance", entry_id: "e1", occurred_on: "2026-11-02", account_id: "a1", balance_minor: -4000000 }],
        names,
      ),
    ).toEqual([
      "Остаток «Kaspi Gold» ушёл в минус 2 ноября 2026: −40\u00a0000\u00a0₸. Кредитов в учёте нет, похоже, пропущена запись.",
    ]);
  });

  it("shows one line per account even if the replay reports several dips", () => {
    const dip = { code: "negative_balance", entry_id: "e1", occurred_on: "2026-11-02", account_id: "a1", balance_minor: -100 };
    expect(warningLines([dip, { ...dip, entry_id: "e2", occurred_on: "2026-11-05" }], names)).toHaveLength(1);
  });

  it("warns softly about a possible duplicate", () => {
    expect(
      warningLines([{ code: "possible_duplicate", entry_id: "e2", duplicate_of: "e1", occurred_on: "2026-11-02" }], names),
    ).toEqual(["Похоже на дубль: такая же запись уже есть 2 ноября 2026. Если это ошибка, удалите лишнюю."]);
  });

  it("ignores unknown warning codes", () => {
    expect(warningLines([{ code: "something_new" }], names)).toEqual([]);
  });
});

describe("entryTitle", () => {
  it("uses the title, then the category, then the type name", () => {
    expect(entryTitle({ type: "expense", title: "Таргет", category_name: "Реклама" })).toBe("Таргет");
    expect(entryTitle({ type: "expense", title: null, category_name: "Реклама" })).toBe("Реклама");
    expect(entryTitle({ type: "income", title: null, category_name: null })).toBe("Поступление");
  });
});

describe("errorDetails", () => {
  it("reads the JSON details of a server error", () => {
    expect(errorDetails({ details: '{"start_date": "2026-11-05"}' })).toEqual({ start_date: "2026-11-05" });
    expect(errorDetails({ details: null })).toEqual({});
  });
});

describe("formatSigned", () => {
  it("puts a plus before income and keeps the minus of a spend", () => {
    expect(formatSigned(2000000, "KZT")).toBe("+20 000 ₸");
    expect(formatSigned(-6000000, "KZT")).toBe("−60 000 ₸");
    expect(formatSigned(0, "KZT")).toBe("0 ₸");
  });
});

describe("advanceReturnErrorText", () => {
  const details = { entry_id: "w1", occurred_on: "2026-11-05", advance_minor: 4000000, amount_minor: 6000000 };

  it("names the advance on the date when the withdrawal itself is too big", () => {
    expect(advanceReturnErrorText(details, true)).toBe("Изъять можно не больше аванса на эту дату: 40\u00a0000\u00a0₸.");
  });

  it("names the later withdrawal that a backdated change would break", () => {
    expect(advanceReturnErrorText(details, false)).toBe(
      "Не получится: изъятие аванса 5 ноября 2026 на 60\u00a0000\u00a0₸ станет больше аванса на ту дату " +
        "(40\u00a0000\u00a0₸). Сначала измените или удалите это изъятие.",
    );
  });
});
