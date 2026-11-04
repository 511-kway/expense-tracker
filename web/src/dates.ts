/** Часовой пояс учёта: «сегодня» и время без зоны трактуются по Алматы (док 04, раздел 12). */
export const ACCOUNTING_TIME_ZONE = "Asia/Almaty";

/** Сегодняшняя дата по Алматы в ISO (YYYY-MM-DD), для значений по умолчанию в полях даты. */
export function todayInAlmaty(now: Date = new Date()): string {
  // en-CA форматирует дату как YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", { timeZone: ACCOUNTING_TIME_ZONE }).format(now);
}

/** ISO-дата → «1 ноября 2026». */
export function formatDate(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  return new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" })
    .format(new Date(Date.UTC(y!, m! - 1, d!)))
    .replace(/\s*г\.$/, "");
}

/** Момент (timestamptz из базы) → «4 ноября 2026, 20:32» по Алматы. */
export function formatDateTime(iso: string): string {
  const moment = new Date(iso);
  const date = formatDate(todayInAlmaty(moment));
  const time = new Intl.DateTimeFormat("ru-RU", {
    hour: "2-digit",
    minute: "2-digit",
    timeZone: ACCOUNTING_TIME_ZONE,
  }).format(moment);
  return `${date}, ${time}`;
}
