/** Коды ошибок сервера (док 05, раздел 5) → текст для экрана. Код приходит в message ошибки RPC. */
const MESSAGES: Record<string, string> = {
  not_allowed: "Добавили вас в лист ожидания",
  missing_required: "Заполните обязательные поля",
  amount_not_positive: "Сумма должна быть больше нуля",
  amount_negative: "Сумма не может быть меньше нуля",
  start_already_set: "Дата начала учёта уже задана",
  debt_below_zero: "Сторона долга не может уйти в минус",
  entry_before_start: "Запись раньше даты старта счёта",
  start_not_set: "Сначала задайте дату начала учёта",
  account_not_found: "Счёт не найден",
  account_name_taken: "Счёт с таким названием уже есть",
  account_currency_locked: "Валюту счёта с операциями менять нельзя",
  archive_nonzero: "Обнулите остаток и аванс перед архивом",
  account_delete_forbidden: "Счёт с операциями можно только архивировать",
  opening_advance_too_big: "Денег компании не может быть больше, чем всего на счёте",
  foreign_opening_not_supported: "Остаток валютного счёта пока можно завести только нулевым",
  currency_invalid: "Выберите валюту из списка",
  category_not_found: "Категория не найдена",
  category_name_taken: "Категория с таким названием уже есть",
  entry_not_found: "Запись не найдена: возможно, её уже удалили",
  field_invalid: "Поле заполнено неверно",
  source_required: "Выберите, чьими деньгами оплачено: на счёте есть аванс",
  foreign_amount_not_supported: "Пока можно записывать только тенге на тенговый счёт: валюта появится позже",
  entry_type_not_supported: "Этот тип записи появится в следующей версии",
  entry_status_not_supported: "Черновики появятся вместе с быстрым вводом",
  debt_overpay: "Погасить можно не больше текущего долга",
  same_account_transfer: "Нельзя перевести на тот же счёт",
  cross_currency_transfer: "Нельзя перевести между счетами в разных валютах",
  advance_return_too_big: "Изъять можно не больше аванса на счёте на эту дату",
  fee_too_big: "Комиссия должна быть меньше суммы пополнения",
  refund_too_big: "Возврат больше суммы исходной траты",
};

export function errorText(error: { message?: string } | null | undefined): string {
  const code = error?.message ?? "";
  return MESSAGES[code] ?? "Сервер не ответил. Попробуйте ещё раз.";
}
