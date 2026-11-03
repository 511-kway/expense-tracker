# Защиты счетов и представления обзора

Status: ready-for-agent
Blocked by: 09

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
- `archive_account` / `unarchive_account`, запрет удаления счёта с операциями, запрет смены валюты.
- `v_settlement_breakdown` (с записями стартового долга и возмещения комиссии), `v_overview` (личные траты за период с учётом `in_analytics`).

## Тесты
TC-ARCHIVE-GUARD, TC-DELETE-ACCOUNT-GUARD, TC-CURRENCY-LOCK; разбивка долга сходится с `v_company_settlement`.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
