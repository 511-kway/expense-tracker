# Корректировки, первый запуск и стартовые остатки

Status: ready-for-agent
Blocked by: 08

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
- `adjustment`: plug_hidden / plug_analytics, `affects_advance`, долговая цель (ADR-0008, док 03 раздел 4.7).
- `setup_start(...)`: дата начала учёта и стартовый долг; повтор запрещён.
- `create_account(...)`: `start_date`, стартовый остаток и аванс корректировками.
- Запрет записей раньше `start_date` / `accounting_start_date` (`entry_before_start`).

## Тесты
TC-ADJUST-HIDDEN, TC-ADJUST-ADVANCE, TC-OPENING, TC-BEFORE-START.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
