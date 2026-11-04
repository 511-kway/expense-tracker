import { DEBT_SIDES, type DebtSide, type EntryWarning } from "./entries";

/** Остаток, аванс и свои одного счёта (тиыны, считает сервер). */
export type AccountCounters = { balance_minor: number; advance_minor: number; own_minor: number };

export type Counters = {
  accounts: Record<string, AccountCounters>;
  company_owes_me_minor: number;
  i_owe_company_minor: number;
};

/** Ответ preview_entry (ADR-0010): затронутые счета, счётчики до, после и дельты, предупреждения. */
export type EntryPreview = {
  ok: true;
  entry_id: string | null;
  status: "done" | "draft";
  warnings: EntryWarning[];
  accounts: { account_id: string; name: string; currency: string }[];
  before: Counters;
  after: Counters;
  deltas: Counters;
};

export type PreviewAccount = {
  account_id: string;
  name: string;
  currency: string;
  before: AccountCounters;
  after: AccountCounters;
  delta: AccountCounters;
};

export type PreviewDebt = { side: DebtSide; label: string; before: number; after: number; delta: number };

const SIDES: DebtSide[] = ["company_owes_me", "i_owe_company"];

/**
 * Ответ предпросмотра → строки для экрана: каждый затронутый счёт со своими до, после и
 * изменением, и только те стороны долга, что сдвинулись. Ничего не считает, только раскладывает.
 */
export function previewLines(p: EntryPreview): { accounts: PreviewAccount[]; debt: PreviewDebt[] } {
  const accounts = p.accounts.flatMap((a) => {
    const before = p.before.accounts[a.account_id];
    const after = p.after.accounts[a.account_id];
    const delta = p.deltas.accounts[a.account_id];
    return before && after && delta ? [{ ...a, before, after, delta }] : [];
  });
  const key = (s: DebtSide) => `${s}_minor` as const;
  const debt = SIDES.filter((s) => p.deltas[key(s)] !== 0).map((s) => ({
    side: s,
    label: DEBT_SIDES[s],
    before: p.before[key(s)],
    after: p.after[key(s)],
    delta: p.deltas[key(s)],
  }));
  return { accounts, debt };
}
