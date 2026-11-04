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

/**
 * Сумма из файла импорта → целые минимальные единицы строкой со знаком: "-1500.00" → "-150000".
 * Отрицательная пишется и минусом, и в скобках: "(1500.00)" (бухгалтерский вид, док 04, раздел 9).
 * Разбор строкой, без float. Больше двух знаков после точки = `amount_too_precise`; разделители
 * тысяч, запятая вместо точки, экспонента и прочее = `amount_invalid` (ошибки строки).
 */
export function parseMoney(text: string): { minor: string } | { error: "amount_invalid" | "amount_too_precise" } {
  const match = /^(?:([+-]?)(\d*)(?:\.(\d*))?|\((\d*)(?:\.(\d*))?\))$/.exec(text.trim());
  if (!match) return { error: "amount_invalid" };
  const negative = match[1] === "-" || match[4] !== undefined;
  const whole = match[2] ?? match[4] ?? "";
  const fraction = match[3] ?? match[5] ?? "";
  if (whole === "" && fraction === "") return { error: "amount_invalid" };
  if (fraction.length > 2) return { error: "amount_too_precise" };
  const digits = (whole + fraction.padEnd(2, "0")).replace(/^0+(?=\d)/, "");
  return { minor: negative && digits !== "0" ? `-${digits}` : digits };
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

// Импорт (тикет 18): строка файла `expenses` → строка импорта для RPC import_preview. Обратное к
// entryRecord: названия счетов и категорий остаются названиями (сопоставляет база по точному
// названию), суммы модулем в минимальных единицах строкой, знак проверяется правилом amountSign,
// у корректировки он становится adjustment_sign. Ошибки ячеек копятся в `errors` строки.

/** Ячейка файла после чтения: текст (числа исходным текстом), логическое или пусто. */
export type FileCell = string | boolean | null;

export type RowError = { field: string; code: string; expected?: "+" | "-" };

export const ENTRY_TYPES = [
  "expense",
  "income",
  "transfer",
  "company_topup",
  "company_advance_return",
  "settlement",
  "netting",
  "adjustment",
  "refund",
] as const;

/** Строка импорта: вход import_preview. Деньги модулем, целыми минимальными единицами строкой. */
export type ImportRow = {
  line: number;
  occurred_on: string | null;
  type: string | null;
  account: string | null;
  amount_minor: string | null;
  currency: string | null;
  category: string | null;
  source: string | null;
  purpose: string | null;
  transfer_purpose: string | null;
  to_account: string | null;
  fee_minor: string | null;
  fee_payer: string | null;
  comment: string | null;
  title: string | null;
  external_id: string | null;
  settlement_direction: string | null;
  adjustment_target: string | null;
  adjustment_mode: string | null;
  adjustment_sign: 1 | -1 | null;
  adjustment_affects_advance: boolean | null;
  parent_external_id: string | null;
  rate: string | null;
  rate_source: string | null;
  amount_kzt_minor: string | null;
  in_analytics: boolean | null;
  errors: RowError[];
};

function isIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(value);
}

function cellText(cell: FileCell | undefined): string | null {
  if (cell === null || cell === undefined) return null;
  const text = String(cell).trim();
  return text === "" ? null : text;
}

/**
 * Строка файла (ключи = колонки ENTRY_COLUMNS, отсутствующая колонка = пусто) → строка импорта.
 * `line`: номер строки в файле (CSV и xlsx: строка листа, шапка = 1; JSON: номер объекта с 1).
 */
export function importRow(line: number, cells: Record<string, FileCell>): ImportRow {
  const errors: RowError[] = [];
  const values: Record<string, string | boolean | null> = {};
  const signs: Record<string, 1 | -1 | null> = {};
  for (const column of ENTRY_COLUMNS) {
    const raw = cells[column.name];
    const text = cellText(raw ?? null);
    values[column.name] = null;
    if (text === null) continue;
    switch (column.kind) {
      case "text":
        values[column.name] = text;
        break;
      case "date":
        if (isIsoDate(text)) values[column.name] = text;
        else errors.push({ field: column.name, code: "field_invalid" });
        break;
      case "rate":
        if (/^\d+(\.\d+)?$/.test(text)) values[column.name] = text;
        else errors.push({ field: column.name, code: "field_invalid" });
        break;
      case "bool": {
        const lower = typeof raw === "boolean" ? String(raw) : text.toLowerCase();
        if (lower === "true" || lower === "false") values[column.name] = lower === "true";
        else errors.push({ field: column.name, code: "field_invalid" });
        break;
      }
      case "money": {
        const parsed = parseMoney(text);
        if ("error" in parsed) {
          errors.push({ field: column.name, code: parsed.error });
        } else {
          const negative = parsed.minor.startsWith("-");
          values[column.name] = negative ? parsed.minor.slice(1) : parsed.minor;
          signs[column.name] = parsed.minor === "0" ? null : negative ? -1 : 1;
        }
        break;
      }
    }
  }

  const type = values.type as string | null;
  if (type === null) {
    if (!errors.some((e) => e.field === "type")) errors.push({ field: "type", code: "missing_required" });
  } else if (!(ENTRY_TYPES as readonly string[]).includes(type)) {
    errors.push({ field: "type", code: "field_invalid" });
  }
  if (cellText(cells.amount ?? null) === null) errors.push({ field: "amount", code: "missing_required" });

  // Знак суммы по правилу файла. Корректировка берёт знак из суммы; у погашения без направления
  // знак не с чем сравнить (база скажет, что направление не заполнено).
  let adjustmentSign: 1 | -1 | null = null;
  const known = type !== null && (ENTRY_TYPES as readonly string[]).includes(type);
  const amountSignOf = signs.amount ?? null;
  if (known && type === "adjustment") {
    adjustmentSign = amountSignOf ?? 1;
  } else if (known && amountSignOf !== null && !(type === "settlement" && values.settlement_direction === null)) {
    const expected = amountSign({ type: type!, settlement_direction: values.settlement_direction as string | null });
    if (amountSignOf !== expected) {
      errors.push({ field: "amount", code: "amount_sign_invalid", expected: sign(expected) });
    }
  }
  if (signs.fee === 1) errors.push({ field: "fee", code: "amount_sign_invalid", expected: "-" });
  const kztSign = signs.amount_kzt ?? null;
  const expectedKzt = type === "adjustment" ? adjustmentSign : amountSignOf;
  if (kztSign !== null && expectedKzt !== null && kztSign !== expectedKzt) {
    errors.push({ field: "amount_kzt", code: "amount_sign_invalid", expected: sign(expectedKzt) });
  }

  const text = (name: string) => values[name] as string | null;
  const bool = (name: string) => values[name] as boolean | null;
  return {
    line,
    occurred_on: text("occurred_on"),
    type,
    account: text("account"),
    amount_minor: text("amount"),
    currency: text("currency"),
    category: text("category"),
    source: text("source"),
    purpose: text("purpose"),
    transfer_purpose: text("transfer_purpose"),
    to_account: text("to_account"),
    fee_minor: text("fee") === "0" ? null : text("fee"),
    fee_payer: text("fee_payer"),
    comment: text("comment"),
    title: text("title"),
    external_id: text("external_id"),
    settlement_direction: text("settlement_direction"),
    adjustment_target: text("adjustment_target"),
    adjustment_mode: text("adjustment_mode"),
    adjustment_sign: adjustmentSign,
    adjustment_affects_advance: bool("adjustment_affects_advance"),
    parent_external_id: text("parent_external_id"),
    rate: text("rate"),
    rate_source: text("rate_source"),
    amount_kzt_minor: text("amount_kzt"),
    in_analytics: bool("in_analytics"),
    errors,
  };
}

function sign(value: 1 | -1): "+" | "-" {
  return value === 1 ? "+" : "-";
}
