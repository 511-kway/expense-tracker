# Переводы: пять назначений и комиссия

Status: ready-for-agent
Blocked by: 05

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
`transfer` по док 03, раздел 4.5: repay_debt, top_up_advance, move_company, take_advance, move_own; комиссия; запрет того же счёта и межвалютного перевода.

## Тесты
TC-TRANSFER-REPAY, TC-REPAY-CAP, TC-MOVE-COMPANY, TC-MOVE-COMPANY-PARTIAL, TC-TAKE-ADVANCE, TC-MOVE-OWN, TC-SAME-ACCOUNT.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
