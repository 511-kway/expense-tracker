/** Коды ошибок сервера (док 05, раздел 5) → текст для экрана. Код приходит в message ошибки RPC. */
const MESSAGES: Record<string, string> = {
  not_allowed: "Добавили вас в лист ожидания",
  missing_required: "Заполните обязательные поля",
  amount_not_positive: "Сумма должна быть больше нуля",
  amount_negative: "Сумма не может быть меньше нуля",
  start_already_set: "Дата начала учёта уже задана",
  debt_below_zero: "Сторона долга не может уйти в минус",
};

export function errorText(error: { message?: string } | null | undefined): string {
  const code = error?.message ?? "";
  return MESSAGES[code] ?? "Сервер не ответил. Попробуйте ещё раз.";
}
