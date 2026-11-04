import { describe, expect, it } from "vitest";
import { previewLines, type EntryPreview } from "./preview";

// TC-EXP-WORK-SPLIT: topup H1 60 000; expense work H1 100 000 (ответ сервера preview_entry).
const workSplit: EntryPreview = {
  ok: true,
  entry_id: null,
  status: "done",
  warnings: [],
  accounts: [{ account_id: "a1", name: "Kaspi Gold", currency: "KZT" }],
  before: {
    accounts: { a1: { balance_minor: 6000000, advance_minor: 6000000, own_minor: 0 } },
    company_owes_me_minor: 0,
    i_owe_company_minor: 0,
  },
  after: {
    accounts: { a1: { balance_minor: -4000000, advance_minor: 0, own_minor: -4000000 } },
    company_owes_me_minor: 4000000,
    i_owe_company_minor: 0,
  },
  deltas: {
    accounts: { a1: { balance_minor: -10000000, advance_minor: -6000000, own_minor: -4000000 } },
    company_owes_me_minor: 4000000,
    i_owe_company_minor: 0,
  },
};

describe("previewLines", () => {
  it("shows the account with its остаток and аванс before, after and the change", () => {
    const { accounts } = previewLines(workSplit);
    expect(accounts).toEqual([
      {
        account_id: "a1",
        name: "Kaspi Gold",
        currency: "KZT",
        before: { balance_minor: 6000000, advance_minor: 6000000, own_minor: 0 },
        after: { balance_minor: -4000000, advance_minor: 0, own_minor: -4000000 },
        delta: { balance_minor: -10000000, advance_minor: -6000000, own_minor: -4000000 },
      },
    ]);
  });

  it("lists only the debt sides that change", () => {
    expect(previewLines(workSplit).debt).toEqual([
      { side: "company_owes_me", label: "Компания должна мне", before: 0, after: 4000000, delta: 4000000 },
    ]);
  });

  it("a netting has no accounts and moves both sides", () => {
    const netting: EntryPreview = {
      ...workSplit,
      accounts: [],
      before: { accounts: {}, company_owes_me_minor: 5000000, i_owe_company_minor: 3000000 },
      after: { accounts: {}, company_owes_me_minor: 3000000, i_owe_company_minor: 1000000 },
      deltas: { accounts: {}, company_owes_me_minor: -2000000, i_owe_company_minor: -2000000 },
    };
    expect(previewLines(netting)).toEqual({
      accounts: [],
      debt: [
        { side: "company_owes_me", label: "Компания должна мне", before: 5000000, after: 3000000, delta: -2000000 },
        { side: "i_owe_company", label: "Я должен компании", before: 3000000, after: 1000000, delta: -2000000 },
      ],
    });
  });
});
