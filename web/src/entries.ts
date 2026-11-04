import { formatMoney, formatRate } from "./money";
import { formatDate } from "./dates";

export type EntryType =
  | "expense"
  | "income"
  | "transfer"
  | "company_topup"
  | "company_advance_return"
  | "settlement"
  | "netting"
  | "adjustment"
  | "refund";

/** Строка ленты из v_entries: поля записи и что она сделала со счётчиками (по журналу сервера). */
export type EntryRow = {
  entry_id: string;
  type: EntryType;
  status: "done" | "draft";
  occurred_on: string;
  amount_minor: number;
  currency: string;
  account_id: string | null;
  account_name: string | null;
  category_id: string | null;
  category_name: string | null;
  purpose: "personal" | "work" | null;
  source: "own" | "company" | null;
  comment: string | null;
  title: string | null;
  balance_delta_minor: number;
  advance_delta_minor: number;
  company_owes_me_delta_minor: number;
  i_owe_company_delta_minor: number;
  fee_minor: number;
  fee_payer: "own" | "company" | null;
  /** Перевод: «куда» и что перевод сделал с ним; дельты выше у перевода по «откуда». */
  transfer_purpose: TransferPurpose | null;
  to_account_id: string | null;
  to_account_name: string | null;
  to_balance_delta_minor: number;
  to_advance_delta_minor: number;
  /** Погашение долга: кто кому отдал. */
  settlement_direction: SettlementDirection | null;
  /** Корректировка: цель, знак, режим и «меняет аванс». */
  adjustment_target: AdjustmentTarget | null;
  adjustment_sign: 1 | -1 | null;
  adjustment_mode: AdjustmentMode | null;
  adjustment_affects_advance: boolean;
  /** Возврат покупки: его трата (дата, сумма, заголовок). */
  parent_entry_id: string | null;
  parent_occurred_on: string | null;
  parent_amount_minor: number | null;
  parent_title: string | null;
  /** Трата: сколько по ней записано возвратов покупки. */
  refunded_minor: number;
  /** Валюта (тикет 14): тенговый эквивалент, курс и способ пересчёта; дельты остатка в валюте счёта. */
  amount_kzt_minor: number;
  rate: number | null;
  rate_source: "nbk" | "manual" | "derived" | null;
  account_currency: string | null;
  /** Черновик быстрого ввода ждёт ответа «чьими деньгами» (ADR-0009). */
  source_pending: boolean;
};

export type AdjustmentTarget = "balance" | DebtSide;
export type AdjustmentMode = "plug_hidden" | "plug_analytics";

/** Стороны долга по GLOSSARY.md. */
export const DEBT_SIDES: Record<DebtSide, string> = {
  company_owes_me: "Компания должна мне",
  i_owe_company: "Я должен компании",
};

export type SettlementDirection = "i_paid_company" | "company_paid_me";

/** Стороны погашения долга по GLOSSARY.md. */
export const SETTLEMENT_DIRECTIONS: Record<SettlementDirection, string> = {
  i_paid_company: "Я отдал компании",
  company_paid_me: "Компания отдала мне",
};

export type DebtSide = "company_owes_me" | "i_owe_company";

/** Строка разбора долга из v_settlement_breakdown: запись, её дельта по стороне и сторона после. */
export type BreakdownRow = {
  entry_id: string;
  side: DebtSide;
  type: EntryType;
  occurred_on: string;
  title: string | null;
  category_name: string | null;
  account_name: string | null;
  to_account_name: string | null;
  purpose: "personal" | "work" | null;
  source: "own" | "company" | null;
  transfer_purpose: TransferPurpose | null;
  settlement_direction: SettlementDirection | null;
  delta_minor: number;
  side_after_minor: number;
  /** Возврат покупки: заголовок его траты. */
  parent_title: string | null;
};

export const BREAKDOWN_COLUMNS =
  "entry_id, side, type, occurred_on, title, category_name, account_name, to_account_name, purpose, source, transfer_purpose, settlement_direction, delta_minor, side_after_minor, parent_title";

export type TransferPurpose = "move_own" | "move_company" | "repay_debt" | "take_advance";

/** Назначения перевода по GLOSSARY.md; «пополнил аванс переводом» убрано (spec.md). */
export const TRANSFER_PURPOSES: Record<TransferPurpose, string> = {
  move_own: "Перевод своих",
  move_company: "Перекладка аванса",
  repay_debt: "Погашение долга в аванс",
  take_advance: "Взял из аванса себе",
};

export const ENTRY_COLUMNS =
  "entry_id, type, status, occurred_on, amount_minor, currency, account_id, account_name, category_id, category_name, purpose, source, comment, title, balance_delta_minor, advance_delta_minor, company_owes_me_delta_minor, i_owe_company_delta_minor, fee_minor, fee_payer, transfer_purpose, to_account_id, to_account_name, to_balance_delta_minor, to_advance_delta_minor, settlement_direction, adjustment_target, adjustment_sign, adjustment_mode, adjustment_affects_advance, parent_entry_id, parent_occurred_on, parent_amount_minor, parent_title, refunded_minor, amount_kzt_minor, rate, rate_source, account_currency, source_pending";

/** Предупреждение из ответа create_entry / update_entry / delete_entry. */
export type EntryWarning =
  | { code: "negative_balance"; entry_id: string; occurred_on: string; account_id: string; balance_minor: number }
  | { code: "possible_duplicate"; entry_id: string; duplicate_of: string; occurred_on: string }
  | { code: string; [key: string]: unknown };

export const TYPE_TITLES: Record<EntryType, string> = {
  expense: "Трата",
  income: "Поступление",
  transfer: "Перевод",
  company_topup: "Пополнение от компании",
  company_advance_return: "Изъятие аванса",
  settlement: "Погашение долга",
  netting: "Взаимозачёт",
  adjustment: "Корректировка",
  refund: "Возврат покупки",
};

/**
 * Заголовок строки ленты: заголовок записи, иначе категория, иначе тип. Возврат покупки без
 * своего заголовка называется по своей трате (её заголовок или категория).
 */
export function entryTitle(
  e: Pick<EntryRow, "type" | "title" | "category_name"> & Partial<Pick<EntryRow, "parent_title">>,
): string {
  if (e.type === "refund" && !e.title) {
    const what = e.parent_title ?? e.category_name;
    return what ? `${TYPE_TITLES.refund}: ${what}` : TYPE_TITLES.refund;
  }
  return e.title ?? e.category_name ?? TYPE_TITLES[e.type];
}

/**
 * Пересчёт валютной записи, мелко в ленте: у тенгового счёта сумма в валюте и курс (остаток
 * списан в тенге), у валютного счёта тенговый эквивалент для аванса и долга. Тенге: null.
 */
export function conversionLabel(
  e: Pick<EntryRow, "currency" | "amount_minor" | "amount_kzt_minor" | "rate" | "rate_source" | "account_currency">,
): string | null {
  if (e.currency === "KZT" || !e.rate_source) return null;
  const how =
    e.rate_source === "derived"
      ? null
      : `по ${e.rate_source === "nbk" ? "курсу Нацбанка" : "своему курсу"} ${e.rate === null ? "" : formatRate(e.rate)}`.trim();
  if (e.account_currency !== null && e.account_currency !== "KZT")
    return [`в тенге ${formatMoney(e.amount_kzt_minor, "KZT")}`, how ?? "введено вручную"].join(" ");
  return how ? `${formatMoney(e.amount_minor, e.currency)} ${how}` : `${formatMoney(e.amount_minor, e.currency)}, в тенге введено вручную`;
}

/** Ссылка возврата покупки на трату, мелко в ленте. */
export function refundLabel(e: Pick<EntryRow, "parent_occurred_on" | "parent_amount_minor" | "currency">): string {
  if (!e.parent_occurred_on || e.parent_amount_minor === null) return "по трате";
  // Возврат покупки в валюте своей траты.
  return `по трате ${formatDate(e.parent_occurred_on)} на ${formatMoney(e.parent_amount_minor, e.currency)}`;
}

/**
 * Ошибка «возврат покупки больше невозвращённого» (refund_too_big, ADR-0006). self = конфликт на
 * самом возврате из формы; иначе правка траты делает её меньше уже записанного возврата.
 */
export function refundTooBigErrorText(details: Record<string, unknown>, self: boolean, currency = "KZT"): string {
  const available = formatMoney(typeof details.available_minor === "number" ? details.available_minor : 0, currency);
  if (self) return `Вернуть можно не больше ${available}: столько по этой трате ещё не вернули.`;
  const amount = typeof details.amount_minor === "number" ? formatMoney(details.amount_minor, currency) : "";
  const date = typeof details.occurred_on === "string" ? formatDate(details.occurred_on) : "позже";
  return (
    `Не получится: возврат покупки ${date}${amount ? ` на ${amount}` : ""} станет больше суммы траты ` +
    `(можно вернуть ${available}). Сначала измените или удалите этот возврат покупки.`
  );
}

/**
 * Предупреждения → строки для экрана. Минус остатка показывается один раз на счёт (первое
 * уход в минус по хронологии), дубль один раз на запись.
 */
export function warningLines(
  warnings: EntryWarning[],
  accountNames: ReadonlyMap<string, string>,
  accountCurrencies: ReadonlyMap<string, string> = new Map(),
): string[] {
  const lines: string[] = [];
  const seen = new Set<string>();
  for (const w of warnings) {
    if (w.code === "negative_balance") {
      const n = w as Extract<EntryWarning, { code: "negative_balance" }>;
      if (seen.has(`neg:${n.account_id}`)) continue;
      seen.add(`neg:${n.account_id}`);
      const name = accountNames.get(n.account_id) ?? "счёта";
      lines.push(
        `Остаток «${name}» ушёл в минус ${formatDate(n.occurred_on)}: ${formatMoney(n.balance_minor, accountCurrencies.get(n.account_id) ?? "KZT")}. ` +
          "Кредитов в учёте нет, похоже, пропущена запись.",
      );
    } else if (w.code === "possible_duplicate") {
      const d = w as Extract<EntryWarning, { code: "possible_duplicate" }>;
      if (seen.has(`dup:${d.entry_id}`)) continue;
      seen.add(`dup:${d.entry_id}`);
      lines.push(`Похоже на дубль: такая же запись уже есть ${formatDate(d.occurred_on)}. Если это ошибка, удалите лишнюю.`);
    }
  }
  return lines;
}

/** Подробности ошибки RPC: сервер кладёт JSON в details (док 05, раздел 5). */
export function errorDetails(error: { details?: string | null }): Record<string, unknown> {
  try {
    const parsed: unknown = JSON.parse(error.details ?? "");
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** Сумма со знаком для ленты: «+20 000 ₸», «−60 000 ₸», ноль без знака. */
export function formatSigned(minor: number, currency: string): string {
  return `${minor > 0 ? "+" : ""}${formatMoney(minor, currency)}`;
}

/**
 * Ошибка «изъять больше аванса» (advance_return_too_big, ADR-0006). self = конфликт на самой
 * записи из формы; иначе правка или удаление задним числом ломает более позднее изъятие.
 */
export function advanceReturnErrorText(details: Record<string, unknown>, self: boolean): string {
  const advance = typeof details.advance_minor === "number" ? details.advance_minor : 0;
  if (self) return `Изъять можно не больше аванса на эту дату: ${formatMoney(advance, "KZT")}.`;
  const amount = typeof details.amount_minor === "number" ? formatMoney(details.amount_minor, "KZT") : "";
  const date = typeof details.occurred_on === "string" ? formatDate(details.occurred_on) : "позже";
  return (
    `Не получится: изъятие аванса ${date}${amount ? ` на ${amount}` : ""} станет больше аванса на ту дату ` +
    `(${formatMoney(advance, "KZT")}). Сначала измените или удалите это изъятие.`
  );
}

/**
 * Ошибка «погасить больше долга» (debt_overpay, ADR-0006) у погашения долга и погашения долга
 * в аванс; side говорит, какая сторона долга. self =
 * конфликт на самой записи из формы; иначе правка или удаление задним числом ломает более
 * позднее погашение.
 */
export function debtOverpayErrorText(details: Record<string, unknown>, self: boolean): string {
  const debt = typeof details.available_minor === "number" ? details.available_minor : 0;
  const who = details.side === "company_owes_me" ? "компания должна вам" : "вы должны компании";
  if (self) return `Погасить можно не больше ${formatMoney(debt, "KZT")}: столько ${who} на эту дату.`;
  const amount = typeof details.amount_minor === "number" ? formatMoney(details.amount_minor, "KZT") : "";
  const date = typeof details.occurred_on === "string" ? formatDate(details.occurred_on) : "позже";
  return (
    `Не получится: погашение долга ${date}${amount ? ` на ${amount}` : ""} станет больше долга на ту дату ` +
    `(${formatMoney(debt, "KZT")}). Сначала измените или удалите это погашение.`
  );
}

/**
 * Ошибка «взаимозачёт больше меньшей стороны» (netting_too_big, ADR-0006). self = конфликт на
 * самой записи из формы; иначе правка или удаление задним числом ломает более поздний взаимозачёт.
 */
export function nettingTooBigErrorText(details: Record<string, unknown>, self: boolean): string {
  const num = (v: unknown) => (typeof v === "number" ? v : 0);
  if (self)
    return (
      `Взаимозачёт не больше меньшей стороны долга: на эту дату компания должна вам ` +
      `${formatMoney(num(details.company_owes_me_minor), "KZT")}, вы должны компании ` +
      `${formatMoney(num(details.i_owe_company_minor), "KZT")}.`
    );
  const amount = typeof details.amount_minor === "number" ? formatMoney(details.amount_minor, "KZT") : "";
  const date = typeof details.occurred_on === "string" ? formatDate(details.occurred_on) : "позже";
  return (
    `Не получится: взаимозачёт ${date}${amount ? ` на ${amount}` : ""} станет больше меньшей стороны долга на ту дату ` +
    `(${formatMoney(num(details.available_minor), "KZT")}). Сначала измените или удалите этот взаимозачёт.`
  );
}

/** Что за запись сдвинула сторону долга: строка разбора на экране «Расчёт с компанией». */
export function breakdownLabel(
  r: Pick<
    BreakdownRow,
    | "type"
    | "title"
    | "category_name"
    | "account_name"
    | "to_account_name"
    | "purpose"
    | "source"
    | "transfer_purpose"
    | "settlement_direction"
  > &
    Partial<Pick<BreakdownRow, "parent_title">>,
): string {
  const at = (name: string | null) => (name ? `, «${name}»` : "");
  switch (r.type) {
    case "expense": {
      const kind = r.purpose === "work" ? "рабочая трата из своих" : "личное деньгами компании";
      return `${r.title ?? r.category_name ?? TYPE_TITLES.expense}: ${kind}${at(r.account_name)}`;
    }
    case "company_topup":
      return `${TYPE_TITLES.company_topup}: возмещение комиссии${at(r.account_name)}`;
    case "transfer":
      if (r.transfer_purpose === "repay_debt") return `${TRANSFER_PURPOSES.repay_debt}${at(r.to_account_name)}`;
      return `${r.transfer_purpose ? TRANSFER_PURPOSES[r.transfer_purpose] : TYPE_TITLES.transfer}${at(r.account_name)}`;
    case "settlement":
      return `${TYPE_TITLES.settlement}${
        r.settlement_direction ? `: ${SETTLEMENT_DIRECTIONS[r.settlement_direction].toLowerCase()}` : ""
      }${at(r.account_name)}`;
    case "refund":
      return `${TYPE_TITLES.refund}: ${r.title ?? r.parent_title ?? r.category_name ?? TYPE_TITLES.expense.toLowerCase()}${at(r.account_name)}`;
    default:
      return r.title ?? TYPE_TITLES[r.type];
  }
}

/**
 * Ошибка «сторона долга уходит в минус» (debt_below_zero, ADR-0006) у долговой корректировки.
 * self = конфликт на самой записи из формы; иначе правка или удаление задним числом ломает более
 * позднюю корректировку.
 */
export function debtBelowZeroErrorText(details: Record<string, unknown>, self: boolean): string {
  const available = formatMoney(typeof details.available_minor === "number" ? details.available_minor : 0, "KZT");
  const side: DebtSide = details.side === "company_owes_me" ? "company_owes_me" : "i_owe_company";
  if (self) {
    const who = side === "company_owes_me" ? "компания должна вам" : "вы должны компании";
    return `Сторона долга не может уйти в минус: на эту дату ${who} ${available}, убрать можно не больше.`;
  }
  const date = typeof details.occurred_on === "string" ? formatDate(details.occurred_on) : "позже";
  return (
    `Не получится: корректировка долга ${date} уведёт «${DEBT_SIDES[side].toLowerCase()}» в минус (на ту дату ${available}). ` +
    "Сначала измените или удалите эту корректировку."
  );
}

/** Что за корректировка, мелко в ленте: режим и аванс у остатка, сторона у долговой. */
export function adjustmentLabel(
  e: Pick<EntryRow, "adjustment_target" | "adjustment_mode" | "adjustment_affects_advance">,
): string {
  if (e.adjustment_target && e.adjustment_target !== "balance")
    return `сторона «${DEBT_SIDES[e.adjustment_target].toLowerCase()}»`;
  const parts = [e.adjustment_mode === "plug_analytics" ? "в разрезах трат" : "скрыта"];
  if (e.adjustment_affects_advance) parts.push("меняет аванс");
  return parts.join(", ");
}
