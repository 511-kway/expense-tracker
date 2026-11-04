# 05. API и RPC

Версия 1. Дата: 2026-11-03.

Поверхность, которую зовёт фронт и Claude Code. Денежные операции идут ТОЛЬКО через RPC-функции Postgres (валидация плюс движок в транзакции). Чтение в основном через представления (views) по PostgREST.

## 1. Принципы

- Запись денег: RPC-функции (`SECURITY DEFINER`, работают в контексте пользователя, уважают RLS по `user_id = auth.uid()`).
- Чтение: PostgREST к таблицам и представлениям, фильтры по RLS.
- Файлы: Supabase Storage (вложения, скрины заметок).
- Внешнее и фоновое: Edge Functions (Deno).
- Клиент не делает прямых INSERT/UPDATE в `entries` и `ledger_entries`.

## 2. RPC-функции (запись)

Все принимают и возвращают JSON. Ошибки возвращаются кодом (раздел 5). Каждая, где меняется баланс, в конце вызывает `recompute` в той же транзакции.

### create_entry(payload) → { entry_id, status }
Создаёт запись любого типа. `payload` зависит от типа (поля в доке 02, матрица применимости). Общие поля:
```
{
  "type": "expense|income|transfer|company_topup|company_advance_return|settlement|netting|adjustment|refund",
  "status": "done|draft",            // по умолчанию done
  "occurred_on": "2026-11-03",
  "occurred_at": "2026-11-03T14:20:00+05:00",  // опционально
  "amount_minor": 840000,            // в тиынах, целое (контракт: только minor)
  "currency": "KZT",
  "amount_kzt_minor": 840000,        // если валюта не KZT
  "rate": null, "rate_source": null,
  "account_id": "...",
  "to_account_id": null,             // transfer
  "category_id": "...",              // expense
  "purpose": "personal|work",        // expense
  "source": "own|company",           // expense personal, если спрошено
  "transfer_purpose": null,
  "fee_minor": 0, "fee_payer": null,
  "settlement_direction": null,
  "adjustment_mode": null, "adjustment_sign": null, "adjustment_affects_advance": false,
  "in_analytics": true,
  "comment": null, "title": null,
  "parent_entry_id": null,           // refund
  "source_note_id": null,
  "external_id": null
}
```
Поведение: валидирует (док 03, раздел 8), вставляет `entries`, вызывает `recompute`. Возвращает id и фактический статус.

Единицы: РЕШЕНО, клиент шлёт и получает суммы только в minor (целое). Отображение делит на 100.

### preview_entry(payload) → { deltas, before, after, warnings }
Тот же payload, что `create_entry` (или `entry_id` плюс payload для правки). Валидирует, применяет, делает `recompute`, сравнивает счётчики до и после, откатывает. Ничего не сохраняет (ADR-0010).

### register_login() → { allowed }
Зовётся фронтом сразу после входа. Upsert в `app_users` по email из JWT, привязка `user_id`, счётчик попыток. Если `allowed = false`, фронт показывает «Добавили вас в лист ожидания» и делает sign out (ADR-0007).

### setup_start(accounting_start_date, company_owes_me_minor, i_owe_company_minor) → { ok }
Первый запуск: фиксирует дату начала учёта и создаёт стартовый долг (ADR-0008). Повторный вызов запрещён.

### create_account(payload) → { account_id }
Создаёт счёт со `start_date`, стартовым остатком и авансом (корректировки на `start_date`), вызывает `recompute`.

### update_entry(entry_id, payload) → { entry_id }
Полная замена полей записи. Пересобирает её ledger, вызывает `recompute`. Смена типа разрешена (полная пересборка). Валидации те же.

### delete_entry(entry_id) → { ok }
Удаляет запись (ledger каскадом), вызывает `recompute`.

### promote_draft(entry_id, payload) → { entry_id }
Дозаполняет черновик (в том числе источник), ставит `status = done`, вызывает `recompute`.

### convert_note_to_entry(note_id, payload) → { entry_id }
Создаёт запись из заметки: вставляет `entries` с `source_note_id = note_id`, ставит заметке `status = processed`, `linked_entry_id`. Вызывает `recompute`.

### archive_account(account_id) → { ok } / unarchive_account(account_id)
Архив при нулевом остатке и авансе, иначе ошибка.

### import_preview(batch) → { batch_id, rows: [...] }
Принимает распарсенные строки (из Edge Function парсинга), валидирует каждую, помечает возможные дубли, НЕ создаёт записи. Возвращает предпросмотр с пометками.

### import_commit(batch_id) → { created, skipped }
Создаёт все строки одной транзакцией как done. Если хоть одна строка невалидна, откат всей партии, `import_batches.status = failed` (ADR-0004). Вызывает `recompute` один раз в конце. Идемпотентность по `external_id`.

### recompute(user_id) → { ok }  (служебная)
Полный реплей (док 03, раздел 7). Обычно вызывается другими функциями, не напрямую клиентом. Можно выставить как админский RPC для ручного пересчёта.

## 3. Представления (чтение, PostgREST)

### v_account_balances
По каждому счёту: `account_id, name, bank, type, currency, balance_minor, advance_minor, own_minor, is_archived`. Выводится из ledger.

### v_company_settlement
Глобально: `company_owes_me_minor, i_owe_company_minor, net_minor` (нетто, знак показывает направление).

### v_settlement_breakdown
Строки операций, формирующих каждую сторону долга (запись × сторона, по журналу): `entry_id, side (company_owes_me|i_owe_company), type, occurred_on, occurred_at, created_at, seq, title, category_name, account_id, account_name, to_account_name, purpose, source, transfer_purpose, settlement_direction, amount_minor, currency, delta_minor, side_after_minor` (сторона после записи в порядке пересчёта). Для раскрытия "из чего сложился долг": стартовый долг и долговые корректировки, траты, возмещение комиссии пополнения, переводы `repay_debt`/`take_advance`, погашения и взаимозачёты.

### v_overview
Агрегаты: `total_balance_minor, total_own_minor, total_company_advance_minor, personal_spend_period_minor` (период параметром или за текущий месяц).

### Прямые таблицы (через PostgREST с RLS)
- `accounts`, `categories` (справочники, чтение и простые правки имени/иконки можно разрешить напрямую, так как они не трогают деньги; создание/архив счёта лучше через RPC для guard).
- `entries` (чтение для лент и инбокса; запись только через RPC).
- `notes` (чтение и создание напрямую можно, так как не трогают баланс; разбор через RPC convert_note_to_entry).
- `ledger_entries` (только чтение, для отладки).

## 4. Edge Functions (Deno)

### fetch_rates(date, currency) → { rate }
Тянет курс Нацбанка РК на дату, кэширует в `fx_rates`. Если уже есть в кэше, отдаёт из базы. Если источник недоступен, возвращает ошибку, клиент предлагает ручной ввод курса или суммы в тенге.

### import_parse(file) → { rows: [...] }
Парсит загруженный CSV/Excel/JSON в массив строк по схеме (док 04, раздел 8). Возвращает строки для `import_preview`. Не пишет в базу.

### claude_ingest(payload, service_token) → { entry_id }
Вход для Claude Code: создаёт запись из разобранной заметки. Проверяет служебный токен (сравнение по хэшу). Дальше та же логика, что `create_entry`. Пишет под `user_id` владельца.

## 5. Коды ошибок

Возвращаются функциями записи. Клиент показывает понятный текст.

| Код | Когда | Текст пользователю |
|---|---|---|
| `amount_not_positive` | сумма ≤ 0 | Сумма должна быть больше нуля |
| `same_account_transfer` | откуда == куда | Нельзя перевести на тот же счёт |
| `cross_currency_transfer` | перевод между счетами разной валюты | Нельзя перевести между счетами в разных валютах |
| `debt_overpay` | settlement/repay больше долга | Погасить можно не больше текущего долга |
| `netting_too_big` | взаимозачёт больше меньшей стороны долга на дату | Взаимозачёт не больше меньшей стороны долга |
| `debt_below_zero` | долговая корректировка уводит сторону долга в минус на дату (пересчёт; `{entry_id, occurred_on, side, available_minor, amount_minor}`) | Сторона долга не может уйти в минус |
| `advance_return_too_big` | изъятие аванса больше аванса на дату | Изъять можно не больше аванса на счёте на эту дату |
| `fee_too_big` | комиссия пополнения не меньше суммы | Комиссия должна быть меньше суммы пополнения |
| `refund_too_big` | возврат больше остатка исходной (пересчёт; `{entry_id, occurred_on, parent_entry_id, available_minor, amount_minor}`) | Возврат больше суммы исходной траты |
| `refund_before_expense` | возврат раньше своей траты (и в пересчёте, если трату перенесли) | Возврат покупки не может быть раньше своей траты |
| `refund_parent_not_expense` | `parent_entry_id` возврата не учтённая трата | Возврат покупки записывается только по трате |
| `expense_has_refunds` | удаление или смена типа траты, по которой есть возврат покупки | По трате записан возврат покупки: сначала удалите его |
| `missing_required` | не заполнено обязательное поле | Заполните обязательные поля |
| `account_currency_locked` | смена валюты счёта с операциями | Валюту счёта с операциями менять нельзя |
| `archive_nonzero` | архив счёта с остатком/авансом | Обнулите остаток и аванс перед архивом |
| `account_delete_forbidden` | удаление счёта с операциями | Счёт с операциями можно только архивировать |
| `account_not_found`, `category_not_found` | импорт, несопоставленное имя | Счёт или категория не найдены |
| `duplicate_external_id` | повтор external_id | Строка уже импортирована |
| `entry_before_start` | дата раньше старта счёта или начала учёта | Запись раньше даты старта счёта |
| `not_allowed` | `app_users.allowed = false` | Добавили вас в лист ожидания |
| `start_already_set` | повторный setup_start | Дата начала учёта уже задана |

## 6. Контракт по единицам и округлению (зафиксировать в реализации)

- Деньги в API в минимальных единицах (целое), чтобы не терять на округлении. Отображение делит на 100 на клиенте.
- Курс `numeric(18,8)`. Тенговый эквивалент считается и округляется до целого тиына на сервере, один раз, при создании.
- Все вычисления сплита и реплея в целых тиынах.
