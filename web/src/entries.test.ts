import { describe, expect, it } from "vitest";
import {
  advanceReturnErrorText,
  breakdownLabel,
  debtOverpayErrorText,
  entryTitle,
  errorDetails,
  formatSigned,
  nettingTooBigErrorText,
  warningLines,
} from "./entries";

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

describe("debtOverpayErrorText", () => {
  it("on the entry itself names the debt on that date", () => {
    expect(debtOverpayErrorText({ available_minor: 3000000, amount_minor: 5000000 }, true)).toBe(
      "Погасить можно не больше 30 000 ₸: столько вы должны компании на эту дату.",
    );
  });

  it("for a later repayment names it with its date and amount", () => {
    expect(
      debtOverpayErrorText({ occurred_on: "2026-11-03", available_minor: 0, amount_minor: 3000000 }, false),
    ).toBe(
      "Не получится: погашение долга 3 ноября 2026 на 30 000 ₸ станет больше долга на ту дату (0 ₸). " +
        "Сначала измените или удалите это погашение.",
    );
  });
});

describe("debtOverpayErrorText for «компания должна мне»", () => {
  it("on the entry itself names what the company owes on that date", () => {
    expect(debtOverpayErrorText({ side: "company_owes_me", available_minor: 2000000, amount_minor: 2500000 }, true)).toBe(
      "Погасить можно не больше 20\u00a0000\u00a0₸: столько компания должна вам на эту дату.",
    );
  });
});

describe("nettingTooBigErrorText", () => {
  const details = {
    occurred_on: "2026-11-03",
    available_minor: 1500000,
    company_owes_me_minor: 1500000,
    i_owe_company_minor: 2500000,
    amount_minor: 2000000,
  };

  it("on the entry itself names the smaller side on that date", () => {
    expect(nettingTooBigErrorText(details, true)).toBe(
      "Взаимозачёт не больше меньшей стороны долга: на эту дату компания должна вам 15\u00a0000\u00a0₸, " +
        "вы должны компании 25\u00a0000\u00a0₸.",
    );
  });

  it("names the later взаимозачёт that a backdated change would break", () => {
    expect(nettingTooBigErrorText(details, false)).toBe(
      "Не получится: взаимозачёт 3 ноября 2026 на 20\u00a0000\u00a0₸ станет больше меньшей стороны долга на ту дату " +
        "(15\u00a0000\u00a0₸). Сначала измените или удалите этот взаимозачёт.",
    );
  });
});

describe("breakdownLabel", () => {
  const base = {
    title: null,
    category_name: null,
    account_name: null,
    to_account_name: null,
    purpose: null,
    source: null,
    transfer_purpose: null,
    settlement_direction: null,
  } as const;

  it("says what kind of entry moved the side of the debt", () => {
    expect(breakdownLabel({ ...base, type: "adjustment", title: "Стартовый долг" })).toBe("Стартовый долг");
    expect(breakdownLabel({ ...base, type: "expense", category_name: "Реклама", purpose: "work", account_name: "H1" })).toBe(
      "Реклама: рабочая трата из своих, «H1»",
    );
    expect(
      breakdownLabel({ ...base, type: "expense", category_name: "Кафе", purpose: "personal", source: "company", account_name: "H1" }),
    ).toBe("Кафе: личное деньгами компании, «H1»");
    expect(breakdownLabel({ ...base, type: "company_topup", account_name: "H1" })).toBe(
      "Пополнение от компании: возмещение комиссии, «H1»",
    );
    expect(breakdownLabel({ ...base, type: "transfer", transfer_purpose: "take_advance", account_name: "H1" })).toBe(
      "Взял из аванса себе, «H1»",
    );
    expect(breakdownLabel({ ...base, type: "transfer", transfer_purpose: "repay_debt", to_account_name: "KS" })).toBe(
      "Погашение долга в аванс, «KS»",
    );
    expect(
      breakdownLabel({ ...base, type: "settlement", settlement_direction: "company_paid_me", account_name: "H1" }),
    ).toBe("Погашение долга: компания отдала мне, «H1»");
    expect(breakdownLabel({ ...base, type: "netting" })).toBe("Взаимозачёт");
  });
});
