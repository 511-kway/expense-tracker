# 02. Модель данных и таблицы

Версия 1. Дата: 2026-11-03.

Это основной документ по данным. Движок и правила расчёта в доке 03.

## 0. Общие правила

- **Деньги целыми.** Все денежные поля это `bigint` в минимальных единицах валюты (тиыны для тенге, центы для доллара и евро, куруши для лиры). 1500 тенге хранится как `150000`. Никакого float и numeric с дробями для денег. Отображение делит на 100 на клиенте.
- **Расчётные величины в тенге.** Аванс и долг всегда в тенге (минимальные единицы, тиыны). Валютные операции несут и свою сумму, и тенговый эквивалент.
- **Каждая строка пользовательских данных несёт `user_id`** (ссылка на `auth.users`), под RLS.
- **Идентификаторы `uuid`**, генерируются базой (`gen_random_uuid()`).
- **Временные метки** `created_at`, `updated_at` типа `timestamptz`, по умолчанию `now()`.
- **Дата операции** `occurred_on` типа `date` (реальная дата, когда операция произошла). Опционально `occurred_at` типа `timestamptz` для точного времени, если оно известно (например, из банковской выписки). Порядок расчёта использует `occurred_on`, затем `occurred_at` при наличии, затем `created_at` как тайбрейк (см. док 03).
- **Баланс нигде не хранится готовым числом.** Остаток, аванс и долг выводятся из `ledger_entries`. Поля-кэши допустимы только как материализованное представление, пересчитываемое движком, но источник правды это журнал.

## 1. Перечисления (enum)

Создаются как Postgres enum или как справочные check-ограничения. Имена значений фиксированы и используются в коде.

- `account_type`: `card`, `bank_account`, `cash`
- `account_owner`: `me`, `spouse`
- `entry_type`: `expense`, `income`, `transfer`, `company_topup`, `company_advance_return`, `settlement`, `adjustment`, `refund`
- `entry_status`: `draft`, `done`
- `purpose`: `personal`, `work`
- `money_source`: `own`, `company`
- `transfer_purpose`: `repay_debt`, `top_up_advance`, `take_advance`, `move_own`, `move_company`
- `fee_payer`: `own`, `company`
- `rate_source`: `nbk`, `manual`, `derived`
- `settlement_direction`: `i_paid_company`, `company_paid_me`
- `adjustment_mode`: `plug_hidden`, `plug_analytics`
- `ledger_target`: `balance`, `card_advance`, `company_owes_me`, `i_owe_company`
- `note_status`: `new`, `processed`
- `adjustment_target`: `balance`, `company_owes_me`, `i_owe_company` (ADR-0008)

## 2. Таблица `accounts` (счета)

Справочник счетов пользователя: карты, банковские счета, наличные.

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK auth.users | not null |
| `name` | text | not null, например "Халык 1" |
| `bank` | text | null для наличных, иначе код банка ("halyk", "kaspi", "kaspi_pay"); используется для цвета и лого |
| `type` | account_type | not null |
| `mask` | text | последние цифры карты или номер счёта, для сверки с выпиской |
| `owner` | account_owner | not null |
| `currency` | text | ISO код, по умолчанию "KZT". Неизменяем после появления операций (см. док 03) |
| `start_date` | date | not null, дата старта счёта, выбирается при создании (default сегодня по Asia/Almaty, не раньше `user_settings.accounting_start_date`), потом неизменна (ADR-0008) |
| `is_archived` | boolean | default false |
| `created_at`, `updated_at` | timestamptz | |

Правила:
- Записи на счёт с `occurred_on < start_date` запрещены (`entry_before_start`).
- Стартовый остаток и аванс счёта заводятся записями `adjustment` на `start_date` (ADR-0008).
- Архив вместо удаления. Удаление запрещено, если на счёт ссылается хотя бы одна запись (FK с `on delete restrict`).
- Нельзя архивировать счёт с ненулевым остатком или ненулевым авансом (проверка в RPC архива).
- Наличные это обычный счёт с `type = cash`, аванса компании обычно не держит, но технически может.

Индексы: `(user_id, is_archived)`.

## 3. Таблица `categories` (категории)

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | not null |
| `name` | text | not null, уникально в рамках пользователя |
| `icon` | text | null, имя иконки |
| `is_archived` | boolean | default false |
| `created_at`, `updated_at` | timestamptz | |

Индексы: уникальный `(user_id, lower(name))`.

## 4. Таблица `entries` (операции, единая)

Все операции в одной таблице, тип в `type`. Набор заполняемых полей зависит от типа (матрица ниже).

| Поле | Тип | Применимость |
|---|---|---|
| `id` | uuid PK | все |
| `user_id` | uuid FK | все |
| `type` | entry_type | все |
| `status` | entry_status | все, default `done`; `draft` для быстрого ввода (импорт черновиков не создаёт, ADR-0004) |
| `occurred_on` | date | все, реальная дата |
| `occurred_at` | timestamptz | опционально, точное время |
| `amount_minor` | bigint | все, сумма операции в своей валюте, минимальные единицы, больше 0 |
| `currency` | text | все, ISO; по умолчанию валюта счёта |
| `amount_kzt_minor` | bigint | все, тенговый эквивалент в тиынах; равен `amount_minor` если валюта KZT |
| `rate` | numeric(18,8) | null если KZT; курс 1 единица валюты в тенге |
| `rate_source` | rate_source | null если KZT |
| `account_id` | uuid FK accounts | expense, income, company_topup, company_advance_return, adjustment, refund; для transfer это счёт-источник ("откуда") |
| `to_account_id` | uuid FK accounts | только transfer ("куда"); not equal `account_id` |
| `category_id` | uuid FK categories | expense (обяз. в полной форме; null допустим для done-траты из быстрого ввода, ADR-0009), income (опц.), refund наследует от исходной; иначе null |
| `purpose` | purpose | только expense (и refund наследует) |
| `source` | money_source | только expense и аналоги; выведен или задан (см. док 03). Null, где неприменимо |
| `source_pending` | boolean | default false; true для черновика, где источник ещё не уточнён |
| `transfer_purpose` | transfer_purpose | только transfer |
| `fee_minor` | bigint | transfer и company_topup, default 0 |
| `fee_payer` | fee_payer | transfer и company_topup, когда есть комиссия |
| `settlement_direction` | settlement_direction | только settlement |
| `adjustment_mode` | adjustment_mode | только adjustment |
| `adjustment_sign` | smallint | только adjustment, `1` или `-1`, знак корректировки остатка |
| `adjustment_affects_advance` | boolean | только adjustment, default false ("это аванс компании"); только при `adjustment_target = balance` |
| `adjustment_target` | adjustment_target | только adjustment, default `balance`; долговые цели для стартового и сверочного долга, `account_id` тогда null (ADR-0008) |
| `in_analytics` | boolean | default true; для `adjustment_mode = plug_hidden` ставится false |
| `comment` | text | все, произвольные пояснения |
| `title` | text | короткий заголовок (для быстрого ввода, корректировки, пакетной записи) |
| `parent_entry_id` | uuid FK entries | только refund и курсовые корректировки: ссылка на исходную операцию |
| `source_note_id` | uuid FK notes | если запись создана из заметки |
| `fingerprint` | text | отпечаток для дедупа (см. док 03) |
| `external_id` | text | ключ идемпотентности при импорте, null для ручных |
| `import_batch_id` | uuid FK import_batches | если пришло импортом |
| `seq` | bigint | bigserial, монотонный номер вставки, последний тайбрейк порядка реплея |
| `created_at`, `updated_at` | timestamptz | |

Ограничения:
- `amount_minor > 0` (знак направления несёт тип и правила движка, не сумма; для корректировки знак несёт отдельное поле, см. ниже).
- Для adjustment сумма может быть со знаком: храним `amount_minor` как модуль плюс поле `adjustment_sign` (`+1` или `-1`), либо допускаем знаковый `amount_signed_minor` отдельным полем. Выбор реализации: отдельное поле `adjustment_sign smallint` (`1` или `-1`), применимое только к adjustment. Остальные типы знак не используют.
- `to_account_id` not null только для transfer, и `to_account_id <> account_id`.
- Валюта операции на одном счёте (трата, поступление и т.п.) может отличаться от валюты счёта: тогда `amount_kzt_minor` несёт тенговый эквивалент, а дельта остатка считается в валюте счёта. Равенства валют тут НЕ требуется.
- Для transfer оба счёта должны быть одной валюты, и перевод в этой же валюте: межвалютных переводов между своими счетами нет (см. док 03).
- `external_id` уникален в рамках `(user_id, import_batch_id)` при наличии.

Индексы:
- `(user_id, occurred_on)` для реплея и лент.
- `(user_id, account_id, occurred_on)` для реплея по счёту.
- `(user_id, fingerprint)` для дедупа.
- `(user_id, status)` для инбокса.
- `(parent_entry_id)`.

### Матрица применимости полей по типам

Легенда: X обязательно, o опционально, пусто неприменимо.

| Поле \ Тип | expense | income | transfer | company_topup | company_advance_return | settlement | adjustment | refund |
|---|---|---|---|---|---|---|---|---|
| account_id | X | X | X (откуда) | X | X | o | X (null для долговой цели) | X |
| to_account_id | | | X (куда) | | | | | |
| amount_minor | X | X | X | X | X | X | X | X |
| currency/amount_kzt | X | X | X | X | X | (KZT) | X | X |
| category_id | X | o | | | | | | наследует |
| purpose | X | | | | | | | наследует |
| source | выводится | | | | | | | наследует |
| transfer_purpose | | | X | | | | | |
| fee_minor/fee_payer | | | o | o | | | | |
| settlement_direction | | | | | | X | | |
| adjustment_mode/sign | | | | | | | X | |
| adjustment_affects_advance | | | | | | | o | |
| parent_entry_id | | | | | | | | X |
| in_analytics | X | X | X | X | X | X | X | X |

Эффект каждого типа на ledger описан в доке 03.

## 5. Таблица `ledger_entries` (журнал движений)

Каждая строка двигает один счётчик на дельту. Баланс любого счётчика = сумма дельт. Это источник правды.

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | not null |
| `entry_id` | uuid FK entries | not null, `on delete cascade` |
| `account_id` | uuid FK accounts | not null для `balance` и `card_advance`; null для долговых счётчиков |
| `target` | ledger_target | not null |
| `delta_minor` | bigint | в тенге для `card_advance`, `company_owes_me`, `i_owe_company`; в валюте счёта для `balance` |
| `occurred_on` | date | дублируется из entry для сортировки реплея |
| `seq` | bigint | порядковый номер для детерминизма (см. док 03) |
| `created_at` | timestamptz | |

Правила:
- Одна запись `entries` порождает от одной до нескольких строк `ledger_entries` (например, трата сверх аванса даёт две строки на один счётчик долга плюс строку на аванс плюс строку на остаток).
- При правке или удалении `entries` его строки `ledger_entries` удаляются и пересоздаются движком (см. recompute в доке 03).
- Долговые дельты (`company_owes_me`, `i_owe_company`) всегда в тенге.
- Дельта остатка (`balance`) в валюте счёта. Для тенговых счетов это тиыны. Валютные счета (например, карта в лирах) ведут остаток в своей валюте.

Индексы:
- `(user_id, account_id, target)` для агрегатов по счёту.
- `(user_id, target)` для общего долга.
- `(entry_id)`.
- `(user_id, account_id, occurred_on, seq)` для реплея.

## 6. Таблица `notes` (заметки)

Свободные пометки и/или скрины, не записи, на баланс не влияют.

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | not null |
| `text` | text | может быть пустым, если есть вложение |
| `attachment_path` | text | путь в Storage, null если только текст |
| `status` | note_status | default `new`; `processed` после разбора |
| `linked_entry_id` | uuid FK entries | запись, созданная из заметки, null пока не разобрана |
| `created_at`, `updated_at` | timestamptz | |

Правило: хотя бы одно из `text` или `attachment_path` не пусто.

Индексы: `(user_id, status)`.

## 7. Таблица `attachments` (вложения записей)

Файлы, привязанные к записи (не к заметке): чек, скрин оплаты, PDF invoice.

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | not null |
| `entry_id` | uuid FK entries | not null, `on delete cascade` |
| `file_path` | text | путь в Storage |
| `kind` | text | "receipt", "screenshot", "invoice" |
| `created_at` | timestamptz | |

## 8. Таблица `fx_rates` (кэш курсов валют)

Дневные курсы Нацбанка РК, чтобы не дёргать источник повторно.

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `rate_date` | date | not null |
| `currency` | text | ISO, not null |
| `rate` | numeric(18,8) | тенге за 1 единицу валюты |
| `source` | text | "nbk" |
| `fetched_at` | timestamptz | |

Уникальный индекс `(rate_date, currency)`. Таблица общая (не на пользователя), RLS только на чтение.

## 9. Таблица `import_batches` (партии импорта)

Для атомарности и идемпотентности импорта.

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK | not null |
| `filename` | text | |
| `format` | text | "csv", "xlsx", "json" |
| `status` | text | "preview", "committed", "failed" |
| `rows_total` | int | |
| `rows_created` | int | |
| `rows_skipped` | int | дубли |
| `created_at` | timestamptz | |

## 10. Пользователи и настройки

### `app_users` (доступ, ADR-0007)

Все, кто пытался войти. Без RLS-доступа с клиента, работает через RPC `register_login()`.

| Поле | Тип | Правила |
|---|---|---|
| `id` | uuid PK | |
| `email` | text | unique, not null, lower-case |
| `user_id` | uuid FK auth.users | null до первого входа |
| `name` | text | из Google профиля |
| `allowed` | boolean | default false; true = может пользоваться |
| `first_seen_at`, `last_attempt_at` | timestamptz | |
| `attempts` | int | default 0 |

Владелец: email из `ADMIN_EMAIL` (`.env`, не в репозитории), при деплое upsert с `allowed = true`. Функция `is_allowed()` входит во все RLS-политики.

### `user_settings`

| Поле | Тип | Правила |
|---|---|---|
| `user_id` | uuid PK FK auth.users | |
| `accounting_start_date` | date | задаётся при первом запуске, потом неизменна (ADR-0008) |
| `timezone` | text | default `Asia/Almaty` |
| `default_currency` | text | default `KZT` |

## 11. Диаграмма связей (словами)

- `accounts`, `categories`, `notes`, `entries`, `ledger_entries`, `attachments`, `import_batches` принадлежат пользователю (`user_id`).
- `entries.account_id` и `entries.to_account_id` ссылаются на `accounts`.
- `entries.category_id` на `categories`.
- `entries.parent_entry_id` на `entries` (refund и курсовые корректировки).
- `entries.source_note_id` на `notes`, и обратно `notes.linked_entry_id` на `entries`.
- `ledger_entries.entry_id` на `entries` (cascade), `ledger_entries.account_id` на `accounts`.
- `attachments.entry_id` на `entries` (cascade).
- `entries.import_batch_id` на `import_batches`.
- `fx_rates` общая, без `user_id`.
