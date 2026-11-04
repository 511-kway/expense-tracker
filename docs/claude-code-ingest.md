# Вход для Claude Code

Claude Code разбирает заметки (текст, скрины чеков) и создаёт записи через Edge Function `claude_ingest`. Правила те же, что у формы: запись проходит `create_entry` / `convert_note_to_entry` / `quick_capture` под владельцем (проверка, движок, пересчёт, лист ожидания).

## Токен

Приложение → «Настройки» → «Доступ для Claude Code» → «Выпустить токен». Токен (`etk_` + 43 символа) показывается один раз; сохраните его в окружение Claude Code, например `export CLAUDE_INGEST_TOKEN=etk_...`. В базе только его SHA-256. «Сменить токен» выпускает новый, старый перестаёт работать сразу; «Отозвать доступ» закрывает вход. Токен действует год, на экране видно, когда его звали последний раз.

## Вызов

`POST <SUPABASE_URL>/functions/v1/claude_ingest`, токен в заголовке `X-Claude-Token` (или `Authorization: Bearer etk_...`), тело JSON до 64 КиБ, не больше 60 вызовов в минуту.

| action | Поля | Что делает |
|---|---|---|
| `context` | — | счета (`id, name, type, currency, start_date`), категории (`id, name`), новые заметки (`id, text, attachment_path, attachment_url, created_at`), `accounting_start_date` |
| `create_entry` | `payload` | запись любого типа, как полная форма (payload по доку 05, суммы целыми тиынами) |
| `convert_note` | `note_id`, `payload` | запись из заметки: заметка становится разобранной, скрин вложением записи |
| `quick_capture` | `payload` | трата как быстрый ввод: без категории можно, при авансе на счёте станет черновиком (ADR-0009) |

`attachment_url` это путь от адреса API, ссылка живёт 10 минут: `curl "$SUPABASE_URL$attachment_url" -o shot.png`.

```bash
URL=http://127.0.0.1:54321/functions/v1/claude_ingest   # прод: https://<домен>/functions/v1/claude_ingest

curl -s -X POST "$URL" -H "X-Claude-Token: $CLAUDE_INGEST_TOKEN" -H "Content-Type: application/json" \
  -d '{"action": "context"}'

curl -s -X POST "$URL" -H "X-Claude-Token: $CLAUDE_INGEST_TOKEN" -H "Content-Type: application/json" -d '{
  "action": "convert_note",
  "note_id": "<id заметки из context>",
  "payload": {"type": "expense", "occurred_on": "2026-11-02", "amount_minor": 250000,
              "account_id": "<id счёта>", "purpose": "work", "category_id": "<id категории>", "title": "Такси"}
}'
```

## Ответ

- `200` — ответ RPC: `{ok: true, entry_id, status, warnings, source_pending}` (+ `note_id` у `convert_note`); у `context` списки выше. `warnings` как у формы: `possible_duplicate`, `negative_balance`.
- Ошибка — `{ok: false, error, details}`, коды дока 05 (раздел 5): `401 token_invalid` (нет, неверный, истёкший или отозванный токен), `403 not_allowed` (владельца сняли с доступа), `429 rate_limited`, `413 payload_too_large`, `400 field_invalid` (`details.field`: `body`, `action`, `note_id`, поле payload), `422` все остальные ошибки проверки и пересчёта (`missing_required`, `amount_not_positive`, `entry_before_start`, `note_already_processed`, …), `502 server_unavailable`.

## Как устроено

Функция считает SHA-256 токена и зовёт RPC `claude_ingest(p_token_hash, p_request)` ключом service_role (другим ролям она закрыта). RPC находит владельца по хэшу в `claude_tokens`, на время вызова ставит его id в JWT-настройки транзакции (`auth.uid()` = владелец) и зовёт ту же RPC записи, что экран. id пользователя из тела запроса не берётся. Ошибка записи не роняет транзакцию: запись откатывается, время вызова и счётчик частоты остаются. Миграция `supabase/migrations/20261120120000_claude_ingest.sql`, функция `supabase/functions/claude_ingest`.
