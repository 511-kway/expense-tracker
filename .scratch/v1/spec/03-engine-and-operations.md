# 03. Движок расчёта и операции

Версия 1. Дата: 2026-11-03.

Это самый важный документ. Здесь точные правила: что делает каждая операция с остатком, авансом и долгом, как считается аванс по порядку, и алгоритм пересчёта. Реализуется функциями Postgres (plpgsql). Клиент эти правила не повторяет.

## 1. Четыре счётчика (ledger targets)

- `balance` (на счёт): сколько всего денег на счёту, в валюте счёта.
- `card_advance` (на счёт): сколько из них денег компании, в тенге. Всегда больше либо равно нулю.
- `company_owes_me` (глобальный): сколько компания должна пользователю, в тенге.
- `i_owe_company` (глобальный): сколько пользователь должен компании, в тенге.

Итог с компанией = сумма `company_owes_me` минус сумма `i_owe_company`.
Свои деньги на счёту = `balance` минус `card_advance` (в тенге для тенговых счетов).
Всего своих денег = сумма (`balance` − `card_advance`) по всем счетам.

Любой счётчик это сумма дельт в `ledger_entries`. Готовых чисел не храним.

## 2. Ключевая сложность: аванс бежит по порядку

Аванс гасится в хронологическом порядке операций. Сколько аванса доступно В МОМЕНТ операции, зависит от порядка. Поэтому дельты аванса и долга для операций, которые тратят аванс, нельзя посчитать в изоляции. Их считает реплей (раздел 7). Дельты остатка (`balance`) порядка не зависят.

Поэтому движок не пишет ledger строки при вставке записи поштучно. Он при любом изменении запускает **recompute** (полный или частичный реплей), который перестраивает ledger. Это гарантирует корректность при записях задним числом, правках и удалениях.

## 3. Авто-сплит (правило деления)

Когда операция хочет потратить денег компании больше, чем доступно аванса на счёту:
- `company_part = min(требуемое, доступный аванс)`
- `own_part = требуемое − company_part`
- аванс списывается на `company_part` (до нуля, в минус не уходит)
- `own_part` идёт дальше из своих денег и даёт долг или нейтрален, по типу операции

Округление: всё в целых тиынах, `company_part` целое, `own_part` это остаток до полной суммы, отдельно не округляется, дрейфа нет.

## 4. Эффект каждого типа операции

Ниже `k` = тенговый эквивалент суммы (`amount_kzt_minor`), `a` = счёт (`account_id`), `to` = счёт назначения (`to_account_id`). Обозначение `adv[a]` = доступный аванс на счёту `a` в момент операции (ведёт реплей).

Важно про дельту остатка. В формулах ниже запись `balance[a] -= amount_minor` это сокращение. Дельта остатка всегда в валюте счёта: для тенгового счёта (обычный случай в MVP, в том числе при валютной операции) это тенговый эквивалент `amount_kzt_minor`, а `amount_minor` совпадает с ним, когда валюта операции и счёта одна (например, карта в лирах и трата в лирах). То есть для тенговой карты трата в долларах уменьшает остаток на тенговый эквивалент, не на доллары. Аванс (`card_advance`) и долг всегда в тенге (`k`).

### 4.1. expense (трата)

Всегда: `balance[a] -= amount_minor` (в валюте счёта).

Назначение work:
```
company_part = min(k, adv[a]); own_part = k - company_part
adv[a] -= company_part
ledger: card_advance[a] -= company_part
if own_part > 0: ledger: company_owes_me += own_part
```

Назначение personal, источник company (возможен только если есть аванс или пользователь явно выбрал):
```
company_part = min(k, adv[a]); own_part = k - company_part
adv[a] -= company_part
ledger: card_advance[a] -= company_part
if company_part > 0: ledger: i_owe_company += company_part
# own_part: свои деньги на личное, нейтрально
```

Назначение personal, источник own: только `balance[a] -= amount_minor`, долг и аванс не трогаются.

Поле `entries.source` ставится как `company`, если `company_part > 0`, иначе `own`. Истинный сплит хранится в ledger строках (это источник правды). Если part и part (смешанный), поле `source` показывает `company`, детали в ledger.

Таблица кейсов трат (справочно):

| Источник | Назначение | Эффект |
|---|---|---|
| свои | работа | company_owes_me += k |
| компании | личное | i_owe_company += company_part, advance -= company_part |
| компании | работа | advance -= company_part, долг не трогается |
| свои | личное | нейтрально |

### 4.2. income (поступление своих денег)

Приход не от компании (зарплата, кешбэк, возврат от человека, продажа).
```
balance[a] += amount_minor
# долг и аванс не трогаются
```

### 4.3. company_topup (пополнение от компании)

Компания отправила деньги на счёт. Поля: `amount_minor` = сколько реально легло на счёт как аванс (landed), `fee_minor` = комиссия, `fee_payer`.
Без комиссии или `fee_payer == company`:
```
adv[a] += amount_kzt_minor
ledger: card_advance[a] += amount_kzt_minor
balance[a] += amount_minor
```
`fee_payer == own` (ADR-0003): комиссия списывается с этого же счёта, сначала из своих денег, нехватка из аванса.
```
balance[a] += amount_minor - fee_minor
own_avail = max(0, bal[a] - adv[a])          # до операции, ведёт реплей
own_part  = min(fee_minor, own_avail)
co_part   = fee_minor - own_part
adv[a] += amount_kzt_minor - co_part
offset = min(own_part, i_owe_company)
ledger: i_owe_company   -= offset
ledger: company_owes_me += own_part - offset
```
Часть комиссии, оплаченная деньгами компании, долг не трогает. UI вычисляет landed из трёх стилей ввода.

### 4.4. company_advance_return (компания забирает неиспользованный аванс)

Валидация: `amount_kzt <= adv[a]` (нельзя вернуть больше, чем есть аванса).
```
adv[a] -= amount_kzt_minor
ledger: card_advance[a] -= amount_kzt_minor
balance[a] -= amount_minor
# долг не трогается
```

### 4.5. transfer (перевод между своими счетами)

Одна валюта у обоих счетов (межвалютных переводов между своими счетами нет). Всегда:
```
balance[a] -= amount_minor
balance[to] += amount_minor
```
Комиссия `fee_minor` (если есть): `balance[a] -= fee_minor`. Если `fee_payer == company`: `adv[a] -= min(fee, adv[a])` (комиссию съели деньги компании). Иначе комиссия из своих, долг не трогается.

Дальше по `transfer_purpose`:

repay_debt (погасил свой долг, свои деньги → карта):
```
валидация: k <= i_owe_company (до нуля; свои на аванс сверх долга не кидаем)
adv[to] += k; ledger: card_advance[to] += k
ledger: i_owe_company -= k
```

move_own (перекладываю свои деньги): только перемещение balance, выше. Больше ничего.

move_company и top_up_advance (перекладываю деньги компании, пополнил аванс переводом): эффект одинаков.
```
company_part = min(k, adv[a])
adv[a] -= company_part; adv[to] += company_part
ledger: card_advance[a] -= company_part; card_advance[to] += company_part
# остаток (k - company_part) это свои деньги, нейтрально
```
Замечание: пополнение аванса, когда деньги приходят ИЗВНЕ от компании (не с другой твоей карты), это тип company_topup, а не transfer.

take_advance (взял аванс себе на личное):
```
company_part = min(k, adv[a])
adv[a] -= company_part
ledger: card_advance[a] -= company_part
ledger: i_owe_company += company_part
# остаток свои деньги, нейтрально; деньги ушли на твой же счёт
```

Таблица назначений перевода:

| transfer_purpose | Эффект |
|---|---|
| repay_debt | advance[to] += k, i_owe_company -= k (до нуля) |
| top_up_advance / move_company | advance[a] -= company_part, advance[to] += company_part |
| take_advance | advance[a] -= company_part, i_owe_company += company_part |
| move_own | только перемещение остатка |

### 4.6. settlement (взаимозачёт)

Поля: `settlement_direction`, `amount_minor` (в тенге), опционально `account_id` (с какого счёта ушло или на какой пришло).

i_paid_company (я вернул компании):
```
валидация: k <= i_owe_company (только до нуля)
ledger: i_owe_company -= k
if account_id: balance[a] -= amount_minor
```

company_paid_me (компания вернула мне):
```
валидация: k <= company_owes_me (только до нуля)
ledger: company_owes_me -= k
if account_id: balance[a] += amount_minor
```

Переход через ноль запрещён. Вернуть можно не больше текущего долга в этом направлении.

### 4.7. adjustment (корректировка остатка)

Поля: `adjustment_mode` (plug_hidden / plug_analytics), `adjustment_sign` (+1 / -1), `amount_minor`, `adjustment_affects_advance`, `adjustment_target` (default `balance`), `in_analytics`.

Долговая цель (`adjustment_target = company_owes_me | i_owe_company`, ADR-0008): `ledger: <target> += adjustment_sign * k`, остаток и аванс не трогаются, `account_id` null, `in_analytics = false`. Счётчик не уходит в минус (проверка реплеем). Используется для стартового долга и сверки с компанией.

Стартовый остаток счёта: две корректировки на `start_date` (остаток на «всего», и `affects_advance` на «из них компании»). Для стартового аванса реплей не режет по `bal`, так как остаток заведён той же датой раньше по seq.

Цель `balance`:
```
s = adjustment_sign * amount_minor
balance[a] += s
if adjustment_affects_advance: adv[a] += s_kzt; ledger: card_advance[a] += s_kzt (clamp adv >= 0)
# долг не трогается
```
`in_analytics`: plug_hidden ставит false (не попадает в разрезы трат), plug_analytics ставит true. Пакетная запись (крупная трата или поступление одной строкой) это НЕ adjustment, а обычный expense или income с крупной суммой и заголовком.

### 4.8. refund (возврат от мерчанта)

Поля: `parent_entry_id` (исходная трата), `amount_minor` (сумма возврата, в валюте исходной), приходит на тот же счёт, с которого платили.

Валидация: `amount_kzt <= (исходная.amount_kzt − сумма прошлых возвратов по ней)`.

Возврат это откат эффекта исходной траты, пропорционально сумме возврата:
```
ρ = amount_kzt / parent.amount_kzt   # доля возврата
balance[parent.account] += amount_minor
# реверс аванса и долга по тому, как делилась исходная (берём её сплит из реплея):
adv[parent.account] += parent.company_part * ρ
реверс ledger долга: company_owes_me -= parent.own_part_work * ρ (если было)
                     i_owe_company   -= parent.company_part_personal * ρ (если было)
```
Округление (целые тиыны, без дрейфа). Для каждой части исходной траты `X` (`company_part`, `own_part`) считаем по НАКОПЛЕННОЙ сумме возвратов `R` (включая текущий):
```
restored_X = floor(X * R / parent.amount_kzt) − уже_восстановлено_X_прошлыми_возвратами
adv[parent.account] += restored_company_part
work:     ledger: company_owes_me -= restored_own_part
personal: ledger: i_owe_company   -= restored_company_part   # own_part нейтрален
```
При полном возврате `R = parent.amount_kzt`, и `floor(X)` = `X` точно, копейки закрываются без остатка.

Курс: откатываем фактически списанный тенговый эквивалент исходной. Если возврат физически пришёл по другому курсу, курсовую разницу заводим ОТДЕЛЬНОЙ записью adjustment (не частью refund).

Так как возврат восстанавливает аванс на дату возврата, реплей сам протянет это в сплиты последующих операций.

## 5. Валюта

- `amount_minor` в валюте операции, `currency` ISO, `amount_kzt_minor` тенговый эквивалент, `rate`, `rate_source`.
- Если `currency == KZT`: `amount_kzt_minor = amount_minor`, `rate = null`.
- Иначе тенговый эквивалент берётся одним из трёх способов (`rate_source`):
  - `nbk`: курс Нацбанка РК на `occurred_on` из таблицы `fx_rates` (Edge Function подтягивает и кэширует). `amount_kzt = round(amount * rate)`.
  - `manual`: пользователь ввёл курс. `amount_kzt = round(amount * rate)`.
  - `derived`: пользователь ввёл сумму в тенге напрямую. `amount_kzt` задан, `rate = amount_kzt / amount` (справочно).
- В расчёт аванса и долга всегда идёт `amount_kzt_minor`.
- Дельта остатка (`balance`) всегда в валюте счёта. Для тенгового счёта это `amount_kzt_minor` (тенговый эквивалент), даже если операция в долларах: тенговую карту списывают в тенге. Для счёта, чья валюта совпадает с валютой операции (например, карта в лирах и трата в лирах), это `amount_minor`. Случай "валютный счёт плюс операция в другой валюте" вне рамок MVP.
- Аванс и долг всегда в тенге. Валютные счета обычно аванса компании не держат (аванс компании приходит в тенге).

## 6. Дедуп (защита от дублей)

- Отпечаток `fingerprint = hash(user_id, occurred_on, account_id, amount_minor, currency, type, normalize(title или category))`.
- Импорт и разбор заметки ищут запись со статусом done и тем же отпечатком в окне ±3 дня. Нашли → помечают строку как возможный дубль в предпросмотре, НЕ создают молча.
- `external_id`: если в импорте есть, он ключ идемпотентности. Повторная загрузка того же файла с теми же `external_id` не плодит дубли (уже созданные пропускаются).
- Ручной ввод: тот же отпечаток в тот же день даёт мягкое предупреждение, не блокирует.

## 7. Алгоритм recompute (реплей)

Сердце движка. Пересобирает `ledger_entries` из `entries`.

Вход: `user_id` (и опционально дата, с которой пересчитывать).
Транзакция целиком.

```
recompute(user_id):
  # 1. выбрать операции (только status = done)
  rows = SELECT * FROM entries
         WHERE user_id = :user AND status = 'done'
         ORDER BY occurred_on,
                  occurred_at NULLS LAST,
                  created_at,
                  seq                 # entries.seq, bigserial
  # 2. очистить ledger
  DELETE FROM ledger_entries WHERE user_id = :user  # (или с даты, см. оптимизацию)
  # 3. состояние
  adv = {}            # account_id -> аванс в тиынах, по умолчанию 0
  bal = {}            # account_id -> остаток (нужен для own_avail, ADR-0003)
  owe_me = 0; i_owe = 0   # долговые счётчики для проверок «до нуля» (ADR-0006)
  split = {}          # entry_id -> запомненный сплит (для refund)
  buffer = []         # новые ledger строки
  # 4. проход
  for e in rows:
     apply_entry(e, adv, split, buffer)   # по правилам раздела 4
  # 5. записать
  INSERT INTO ledger_entries SELECT * FROM buffer
```

Правила:
- Черновики (`status = draft`) в реплей НЕ входят, на баланс не влияют.
- Порядок строго детерминированный: `occurred_on`, затем `occurred_at` (если есть), затем `created_at`, затем `seq` (монотонный счётчик вставки). Тайбрейк гарантирует стабильность при одинаковых датах.
- `apply_entry` для операций, трогающих два счёта (transfer), обновляет `adv` обоих.
- Для refund `apply_entry` берёт сплит родителя из `split[parent_entry_id]` (родитель раньше в порядке) и реверсит пропорционально.
- Ограничения «до нуля» проверяются В РЕПЛЕЕ на момент каждой операции (ADR-0006): settlement и repay_debt не больше долга на эту дату, company_advance_return не больше аванса на эту дату, refund не больше остатка исходной. Нарушение = исключение с кодом ошибки и id операции, откат всей транзакции. Так ловятся правки и удаления задним числом.

### Когда вызывается recompute

- После создания, правки или удаления любой записи со `status = done`.
- Когда черновик становится `done` (разобран).
- После импорта партии (один recompute в конце партии).

### Оптимизация (не обязательна в MVP)

Полный реплей дешёвый (тысячи записей, миллисекунды). Если понадобится: хранить снапшот `adv` на начало каждого дня, при изменении пересчитывать только с `min(затронутая дата)` вперёд. В MVP делаем полный реплей, это проще и надёжнее.

## 8. Валидация (сводка проверок перед записью)

Проверяется в RPC создания или правки, до запуска движка. Пункты 3-6 дополнительно (и окончательно) проверяются реплеем по хронологии (ADR-0006):

1. `amount_minor > 0` (для adjustment модуль, знак в `adjustment_sign`).
2. transfer: `to_account_id` задан, `to_account_id <> account_id`, валюта обоих счетов совпадает.
3. repay_debt: `amount_kzt <= текущий i_owe_company`.
4. settlement i_paid_company: `amount_kzt <= текущий i_owe_company`. company_paid_me: `amount_kzt <= текущий company_owes_me`.
5. company_advance_return: `amount_kzt <= текущий card_advance[account]`.
6. refund: `amount_kzt <= (parent.amount_kzt − уже возвращённое по parent)`; `parent` это expense; возврат на `parent.account`.
7. Обязательные поля по типу (см. матрицу в доке 02).
8. Валюта. Для transfer оба счёта одной валюты и перевод в этой валюте (межвалютных переводов между своими счетами нет). Для одиночных операций (трата, поступление и т.п.) валюта операции может отличаться от валюты счёта: тогда обязателен тенговый эквивалент `amount_kzt` (и курс или прямой ввод суммы в тенге).
9. Неизменность: валюту счёта с операциями менять нельзя; тип записи при правке = полная пересборка её ledger строк (не точечная правка).
10. Архив счёта: `balance == 0` и `card_advance == 0`. Удаление счёта запрещено при наличии ссылающихся записей (только архив).
11. Дата операции: допускается прошлое (задним числом); реплей разберётся. Но не раньше `accounts.start_date` счёта (и `to_account` для перевода), а для записей без счёта не раньше `user_settings.accounting_start_date` (`entry_before_start`, ADR-0008).
12. Доступ: `is_allowed()` (`not_allowed`, ADR-0007).

Ошибки валидации возвращаются клиенту понятным кодом и текстом (см. док 05).

## 9. Разбор черновика и заметки

- Быстрый ввод сразу создаёт done, если движку хватает данных для расчёта; иначе draft (ADR-0009).
- Черновик (быстрый ввод) имеет неполные поля и, возможно, `source_pending = true`. В инбоксе пользователь дозаполняет (в том числе источник, если на счёте есть аванс), статус переходит в `done`, вызывается recompute.
- Заметка не запись. Из заметки создаётся запись (вручную или через Claude Code): создаётся `entries` со ссылкой `source_note_id`, заметке ставится `status = processed` и `linked_entry_id`.

## 10. Инвариант (чем проверять корректность)

В любой момент после recompute должно выполняться:
- Для каждого счёта: `card_advance >= 0`.
- Для каждого счёта: сумма дельт `balance` по ledger равна фактическому остатку, который ведёт пользователь (с точностью до незакрытых корректировок).
- `company_owes_me >= 0` и `i_owe_company >= 0` (счётчики не уходят в минус; переход через ноль запрещён правилами settlement).
- Итог с компанией = сумма `company_owes_me` − сумма `i_owe_company`.

Эти инварианты проверяются тестами (док 06).
