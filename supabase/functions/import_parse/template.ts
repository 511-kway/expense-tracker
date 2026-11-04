// Шаблон файла импорта: файл `expenses` той же схемы, что пишет экспорт, с примерами строк.
// Строится тем же кодом экспорта (entryRecord, renderFile), поэтому не может разойтись со схемой.
import { ENTRY_COLUMNS, entryRecord, type ExportEntryRow } from "../_shared/schema.ts";
import { type ExportFormat, renderFile } from "../export/format.ts";

const blank: ExportEntryRow = {
  occurred_on: "2026-11-02",
  type: "expense",
  account_name: "Kaspi Gold",
  amount_minor: "0",
  currency: "KZT",
  category_name: null,
  source: null,
  purpose: null,
  transfer_purpose: null,
  to_account_name: null,
  fee_minor: "0",
  fee_payer: null,
  comment: null,
  title: null,
  external_id: "",
  settlement_direction: null,
  adjustment_target: null,
  adjustment_mode: null,
  adjustment_sign: null,
  adjustment_affects_advance: false,
  parent_external_id: null,
  rate: null,
  rate_source: null,
  amount_kzt_minor: null,
  in_analytics: true,
};

/** Примеры: по строке на частые случаи. Названия счетов и категорий замените своими. */
export const TEMPLATE_ROWS: ExportEntryRow[] = [
  {
    ...blank,
    amount_minor: "1500000",
    category_name: "Реклама",
    purpose: "work",
    title: "Таргет",
    external_id: "bank-0001",
  },
  {
    ...blank,
    amount_minor: "250000",
    category_name: "Еда",
    purpose: "personal",
    source: "own",
    title: "Продукты",
    external_id: "bank-0002",
  },
  {
    ...blank,
    occurred_on: "2026-11-03",
    type: "income",
    amount_minor: "50000000",
    title: "Зарплата",
    external_id: "bank-0003",
  },
  {
    ...blank,
    occurred_on: "2026-11-03",
    type: "transfer",
    amount_minor: "10000000",
    to_account_name: "Halyk",
    transfer_purpose: "move_own",
    fee_minor: "50000",
    fee_payer: "own",
    external_id: "bank-0004",
  },
  {
    ...blank,
    occurred_on: "2026-11-05",
    type: "refund",
    amount_minor: "500000",
    category_name: "Реклама",
    purpose: "work",
    parent_external_id: "bank-0001",
    external_id: "bank-0005",
  },
];

export async function templateFile(format: ExportFormat): Promise<Uint8Array> {
  return await renderFile(format, "expenses", ENTRY_COLUMNS, TEMPLATE_ROWS.map(entryRecord));
}
