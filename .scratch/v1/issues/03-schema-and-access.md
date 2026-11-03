# Схема данных, RLS и доступ через app_users

Status: ready-for-agent
Blocked by: 02

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
Миграции по док 02 целиком: все enum (включая `adjustment_target`), таблицы `accounts` (с `start_date`), `categories`, `entries` (с `seq bigserial`), `ledger_entries`, `notes`, `attachments`, `fx_rates`, `import_batches`, `app_users`, `user_settings`, индексы, FK.

- `app_users`; владелец берётся из `ADMIN_EMAIL` (`.env`) и при деплое/`db reset` upsert-ится с `allowed = true` (ADR-0007). В репозитории email не хранится.
- `is_allowed()` и RLS `user_id = auth.uid() AND is_allowed()` на всех пользовательских таблицах. `entries` и `ledger_entries` с клиента только чтение.
- RPC `register_login()`.

## Тесты
TC-RLS, TC-WAITLIST.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
