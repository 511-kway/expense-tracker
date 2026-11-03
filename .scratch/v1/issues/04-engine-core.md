# Ядро движка: recompute, create/update/delete, income и личная трата своими

Status: ready-for-agent
Blocked by: 03

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
Скелет движка, на который дальше навешиваются типы операций.

- `recompute(user_id)`: полный реплей по порядку `occurred_on, occurred_at NULLS LAST, created_at, seq`, состояние `adv`, `bal`, `owe_me`, `i_owe`, `split` (док 03, раздел 7). Механизм ошибок реплея с кодом и id операции (ADR-0006).
- `create_entry`, `update_entry`, `delete_entry`: суммы в minor (док 05), валидация обязательных полей, `is_allowed()`, recompute в той же транзакции.
- Типы: `income`, `expense` personal own.
- Представления `v_account_balances`, `v_company_settlement`.

## Тесты
TC-INCOME, TC-EXP-PERS-OWN, TC-RECOMPUTE-IDEMPOTENT.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
