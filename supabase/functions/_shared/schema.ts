// Единая схема плоских файлов экспорта и импорта (док 04, разделы 8 и 9). Экспорт (тикет 17) пишет
// по ней, импорт (тикет 18) читает по ней же: колонки, их порядок и правило знака определены только
// здесь. Описание для людей и Claude в доке 04, раздел 8.
//
// Деньги приходят из базы строкой целых минимальных единиц ("150000") и в файл уходят строкой
// основных единиц ровно с двумя знаками ("1500.00"); float нигде не участвует.

/** Вид значения колонки: от него зависит, как значение пишется в CSV, JSON и xlsx. */
export type ColumnKind = "date" | "text" | "money" | "rate" | "bool";

export type Column = { readonly name: string; readonly kind: ColumnKind };

/** Сумма в основных единицах со знаком, ровно два знака после точки: "-1500.00". */
export type Money = { readonly money: string };

export type Value = string | boolean | Money | null;

export type FileRecord = Record<string, Value>;

/**
 * Файл `expenses`: одна строка = одна учтённая запись. Первые 15 колонок из дока 04, раздел 8;
 * дальше поля типов, появившихся позже (погашение, корректировка, возврат покупки, валюта).
 */
export const ENTRY_COLUMNS: readonly Column[] = [
  { name: "occurred_on", kind: "date" },
  { name: "type", kind: "text" },
  { name: "account", kind: "text" },
  { name: "amount", kind: "money" },
  { name: "currency", kind: "text" },
  { name: "category", kind: "text" },
  { name: "source", kind: "text" },
  { name: "purpose", kind: "text" },
  { name: "transfer_purpose", kind: "text" },
  { name: "to_account", kind: "text" },
  { name: "fee", kind: "money" },
  { name: "fee_payer", kind: "text" },
  { name: "comment", kind: "text" },
  { name: "title", kind: "text" },
  { name: "external_id", kind: "text" },
  { name: "settlement_direction", kind: "text" },
  { name: "adjustment_target", kind: "text" },
  { name: "adjustment_mode", kind: "text" },
  { name: "adjustment_affects_advance", kind: "bool" },
  { name: "parent_external_id", kind: "text" },
  { name: "rate", kind: "rate" },
  { name: "rate_source", kind: "text" },
  { name: "amount_kzt", kind: "money" },
  { name: "in_analytics", kind: "bool" },
];

/**
 * Файл `company_settlement`: одна строка = одна запись, двигавшая долг, с изменением каждой
 * стороны и обеими сторонами после неё. Только экспорт (выводится из журнала, импорт его не читает);
 * общие с `expenses` колонки названы так же, `external_id` связывает строку с записью.
 */
export const SETTLEMENT_COLUMNS: readonly Column[] = [
  { name: "occurred_on", kind: "date" },
  { name: "type", kind: "text" },
  { name: "account", kind: "text" },
  { name: "to_account", kind: "text" },
  { name: "title", kind: "text" },
  { name: "category", kind: "text" },
  { name: "purpose", kind: "text" },
  { name: "source", kind: "text" },
  { name: "transfer_purpose", kind: "text" },
  { name: "settlement_direction", kind: "text" },
  { name: "currency", kind: "text" },
  { name: "company_owes_me_change", kind: "money" },
  { name: "i_owe_company_change", kind: "money" },
  { name: "company_owes_me_after", kind: "money" },
  { name: "i_owe_company_after", kind: "money" },
  { name: "net_after", kind: "money" },
  { name: "external_id", kind: "text" },
];

/** Целые минимальные единицы строкой → основные единицы с двумя знаками: "-150000" → "-1500.00". */
export function minorToMajor(minor: string | number | bigint): string {
  const text = String(minor);
  const match = /^(-?)(\d+)$/.exec(text);
  if (!match) throw new Error(`not an integer amount of minor units: ${text}`);
  const digits = match[2]!.replace(/^0+(?=\d)/, "").padStart(3, "0");
  const sign = match[1] && /[1-9]/.test(digits) ? "-" : "";
  return `${sign}${digits.slice(0, -2)}.${digits.slice(-2)}`;
}

/** Курс из базы ("480.00000000") без хвостовых нулей: "480", "453.64". */
export function trimRate(rate: string): string {
  return rate.includes(".") ? rate.replace(/0+$/, "").replace(/\.$/, "") : rate;
}

/**
 * Правило знака суммы в файле (док 04, раздел 8). В базе сумма всегда больше нуля, направление
 * несёт тип; в файле знак = движение денег по счёту из колонки `account`:
 *   минус: трата, перевод (уходит с «откуда»), изъятие аванса, погашение «я отдал компании»;
 *   плюс:  поступление, пополнение от компании, возврат покупки, погашение «компания отдала мне»,
 *          взаимозачёт (счёта нет, денег не двигает: всегда плюс);
 *   корректировка: знак корректировки (`adjustment_sign`), и для остатка, и для стороны долга.
 * Комиссия (`fee`) это всегда списание: минус, пусто когда комиссии нет. `amount_kzt` со знаком
 * `amount`. Импорт по этому же правилу выводит знак корректировки, а у остальных типов знак
 * должен совпасть с правилом.
 */
export function amountSign(
  entry: { type: string; settlement_direction?: string | null; adjustment_sign?: number | null },
): 1 | -1 {
  switch (entry.type) {
    case "expense":
    case "transfer":
    case "company_advance_return":
      return -1;
    case "income":
    case "company_topup":
    case "refund":
    case "netting":
      return 1;
    case "settlement":
      return entry.settlement_direction === "i_paid_company" ? -1 : 1;
    case "adjustment":
      return entry.adjustment_sign === -1 ? -1 : 1;
    default:
      throw new Error(`unknown entry type: ${entry.type}`);
  }
}

function money(minor: string | number | null | undefined, sign: 1 | -1 = 1): Money | null {
  if (minor === null || minor === undefined) return null;
  const major = minorToMajor(minor);
  return { money: sign === -1 && !major.startsWith("-") && major !== "0.00" ? `-${major}` : major };
}

/** Строка выборки v_export_entries; деньги и курс строкой (select `amount_minor::text`). */
export type ExportEntryRow = {
  occurred_on: string;
  type: string;
  account_name: string | null;
  amount_minor: string;
  currency: string;
  category_name: string | null;
  source: string | null;
  purpose: string | null;
  transfer_purpose: string | null;
  to_account_name: string | null;
  fee_minor: string;
  fee_payer: string | null;
  comment: string | null;
  title: string | null;
  external_id: string;
  settlement_direction: string | null;
  adjustment_target: string | null;
  adjustment_mode: string | null;
  adjustment_sign: number | null;
  adjustment_affects_advance: boolean;
  parent_external_id: string | null;
  rate: string | null;
  rate_source: string | null;
  amount_kzt_minor: string | null;
  in_analytics: boolean;
};

/** Запись → строка файла `expenses` по ENTRY_COLUMNS. */
export function entryRecord(row: ExportEntryRow): FileRecord {
  const sign = amountSign(row);
  const isAdjustment = row.type === "adjustment";
  return {
    occurred_on: row.occurred_on,
    type: row.type,
    account: row.account_name,
    amount: money(row.amount_minor, sign),
    currency: row.currency,
    category: row.category_name,
    source: row.source,
    purpose: row.purpose,
    transfer_purpose: row.transfer_purpose,
    to_account: row.to_account_name,
    fee: row.fee_minor && row.fee_minor !== "0" ? money(row.fee_minor, -1) : null,
    fee_payer: row.fee_payer,
    comment: row.comment,
    title: row.title,
    external_id: row.external_id,
    settlement_direction: row.settlement_direction,
    adjustment_target: row.adjustment_target,
    adjustment_mode: row.adjustment_mode,
    adjustment_affects_advance: isAdjustment && row.adjustment_target === "balance"
      ? row.adjustment_affects_advance
      : null,
    parent_external_id: row.parent_external_id,
    rate: row.rate === null ? null : trimRate(row.rate),
    rate_source: row.rate_source,
    amount_kzt: money(row.amount_kzt_minor, sign),
    in_analytics: row.in_analytics,
  };
}

/** Строка выборки v_settlement_movements; деньги строкой со знаком журнала. */
export type SettlementMovementRow = {
  occurred_on: string;
  type: string;
  account_name: string | null;
  to_account_name: string | null;
  title: string | null;
  parent_title: string | null;
  category_name: string | null;
  purpose: string | null;
  source: string | null;
  transfer_purpose: string | null;
  settlement_direction: string | null;
  currency: string;
  company_owes_me_delta_minor: string;
  i_owe_company_delta_minor: string;
  company_owes_me_after_minor: string;
  i_owe_company_after_minor: string;
  net_after_minor: string;
  external_id: string;
};

/**
 * Движение → строка файла `company_settlement` по SETTLEMENT_COLUMNS. Изменения со знаком журнала
 * (сторона выросла = плюс), стороны после не меньше нуля, итог после = «компания должна мне» минус
 * «я должен компании». У возврата покупки заголовок его траты, если своего нет.
 */
export function settlementRecord(row: SettlementMovementRow): FileRecord {
  return {
    occurred_on: row.occurred_on,
    type: row.type,
    account: row.account_name,
    to_account: row.to_account_name,
    title: row.title ?? row.parent_title,
    category: row.category_name,
    purpose: row.purpose,
    source: row.source,
    transfer_purpose: row.transfer_purpose,
    settlement_direction: row.settlement_direction,
    currency: row.currency,
    company_owes_me_change: money(row.company_owes_me_delta_minor),
    i_owe_company_change: money(row.i_owe_company_delta_minor),
    company_owes_me_after: money(row.company_owes_me_after_minor),
    i_owe_company_after: money(row.i_owe_company_after_minor),
    net_after: money(row.net_after_minor),
    external_id: row.external_id,
  };
}
