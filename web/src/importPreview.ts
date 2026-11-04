import { formatMoney } from "./money";
import { errorText } from "./errors";

/** Ошибка всего файла из import_parse (не читается, нет колонок). */
export type FileError = { code: string; columns?: string[]; limit?: number };

/** Ошибка строки из import_parse или import_preview / import_commit. */
export type RowError = { code: string; field?: string | null; expected?: "+" | "-"; details?: Record<string, unknown> };

/** Строка импорта от import_parse (вход import_preview); деньги целыми тиынами строкой. */
export type ImportRow = {
  line: number;
  occurred_on: string | null;
  currency: string | null;
  rate_source: string | null;
  errors: RowError[];
  [field: string]: unknown;
};

export type Duplicate = { entry_id: string; occurred_on: string; title?: string; amount_minor?: number; line?: number };

/** Строка отчёта import_preview / import_commit. */
export type PreviewRow = {
  line: number;
  status: "create" | "skip" | "excluded" | "error";
  errors: RowError[];
  duplicates: Duplicate[];
  entry_id: string | null;
  type: string | null;
  occurred_on: string | null;
  account: string | null;
  to_account: string | null;
  category: string | null;
  title: string | null;
  amount_minor: string | null;
  currency: string | null;
  adjustment_sign: number | null;
  external_id: string | null;
};

export type Preview = {
  batch_id: string;
  status: "preview" | "committed" | "failed";
  rows: PreviewRow[];
  rows_total: number;
  rows_create: number;
  rows_skip: number;
  rows_error: number;
  rows_duplicate: number;
};

/** Пары «дата, валюта», для которых нужен курс Нацбанка в кэше до предпросмотра. */
export function nbkRatePairs(
  rows: readonly Pick<ImportRow, "occurred_on" | "currency" | "rate_source">[],
): { date: string; currency: string }[] {
  const seen = new Set<string>();
  const pairs: { date: string; currency: string }[] = [];
  for (const r of rows) {
    if (r.rate_source !== "nbk" || !r.occurred_on || !r.currency || r.currency === "KZT") continue;
    const key = `${r.occurred_on}|${r.currency}`;
    if (seen.has(key)) continue;
    seen.add(key);
    pairs.push({ date: r.occurred_on, currency: r.currency });
  }
  return pairs;
}

/** Колонки файла словами экрана. */
export const COLUMN_LABELS: Record<string, string> = {
  occurred_on: "Дата",
  type: "Тип",
  account: "Счёт",
  amount: "Сумма",
  currency: "Валюта",
  category: "Категория",
  source: "Чьими деньгами",
  purpose: "Назначение",
  transfer_purpose: "Назначение перевода",
  to_account: "Счёт «куда»",
  fee: "Комиссия",
  fee_payer: "Кто платит комиссию",
  comment: "Комментарий",
  title: "Название",
  external_id: "Внешний идентификатор",
  settlement_direction: "Направление погашения",
  adjustment_target: "Что корректируется",
  adjustment_mode: "Режим корректировки",
  adjustment_affects_advance: "Деньги компании",
  parent_external_id: "Трата возврата",
  rate: "Курс",
  rate_source: "Источник курса",
  amount_kzt: "Сумма в тенге",
  in_analytics: "В аналитике",
};

const IMPORT_MESSAGES: Record<string, string> = {
  amount_too_precise: "больше двух знаков после точки",
  amount_invalid: "не число: пишите 1500.00, -1500.00 или (1500.00), без пробелов и запятых",
  field_invalid: "значение не по схеме",
  missing_required: "заполните поле",
  duplicate_external_id: "такой внешний идентификатор уже есть выше в файле",
};

/** Ошибка строки → текст: колонка и что не так. */
export function rowErrorText(error: RowError): string {
  const label = error.field ? COLUMN_LABELS[error.field] ?? error.field : null;
  const name = typeof error.details?.name === "string" ? error.details.name : null;
  if (error.code === "account_not_found" && name)
    return `Счёт «${name}» не найден: названия счетов сопоставляются точно`;
  if (error.code === "category_not_found" && name)
    return `Категория «${name}» не найдена: названия категорий сопоставляются точно`;
  if (error.code === "amount_sign_invalid")
    return `${label ?? "Сумма"}: у этого типа записи сумма со знаком ${error.expected === "-" ? "минус" : "плюс"}`;
  if (error.code === "entry_not_found" && error.field === "parent_external_id")
    return "Трата возврата не найдена: ни в базе, ни выше в файле нет записи с таким external_id";
  const own = IMPORT_MESSAGES[error.code];
  if (own) return label ? `${label}: ${own}` : own.charAt(0).toUpperCase() + own.slice(1);
  return errorText({ message: error.code });
}

/** Ошибка файла целиком → текст. */
export function fileErrorText(error: FileError): string {
  switch (error.code) {
    case "columns_missing":
      return `В файле нет колонок ${(error.columns ?? []).join(", ")}. Скачайте шаблон: в нём все колонки.`;
    case "columns_unknown":
      return `Колонки ${(error.columns ?? []).join(", ")} не из схемы. Переименуйте или удалите их.`;
    case "format_unsupported":
      return "Загрузите файл CSV, Excel (xlsx), JSON или архив экспорта (zip).";
    case "zip_without_expenses":
      return "В архиве нет файла expenses: загрузите архив экспорта или сам файл.";
    case "file_empty":
      return "В файле нет строк с записями.";
    case "too_many_rows":
      return `Больше ${error.limit ?? 5000} строк за раз не загрузить: разделите файл.`;
    case "file_too_large":
      return "Файл больше 10 МБ: разделите его на части.";
    default:
      return "Файл не читается: проверьте, что это CSV в UTF-8, xlsx или JSON-массив объектов.";
  }
}

/** Сумма строки для экрана. Сервер шлёт тиыны строкой, модулем; знак у строки задаёт тип. */
export function rowAmount(row: Pick<PreviewRow, "amount_minor" | "currency">): string {
  if (row.amount_minor === null) return "";
  const minor = Number(row.amount_minor);
  return Number.isSafeInteger(minor) ? formatMoney(minor, row.currency ?? "KZT") : row.amount_minor;
}

/** Возможные дубли по умолчанию не создаются: владелец оставляет нужные сам (ADR-0004). */
export function defaultExcluded(rows: readonly PreviewRow[]): number[] {
  return rows.filter((r) => r.status === "create" && r.duplicates.length > 0).map((r) => r.line);
}
