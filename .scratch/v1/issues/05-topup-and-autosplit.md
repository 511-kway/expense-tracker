# Пополнение от компании и траты с авто-сплитом

Status: ready-for-agent
Blocked by: 04

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
- `company_topup` без комиссии и с `fee_payer = company` (док 03, раздел 4.3).
- `expense` work и personal company с авто-сплитом (раздел 3, 4.1), `entries.source` по фактическому сплиту.
- Хронологический реплей по реальной дате.

## Тесты
TC-TOPUP-1, TC-EXP-WORK-WITHIN, TC-EXP-WORK-SPLIT, TC-EXP-PERS-COMPANY, TC-EXP-PERS-COMPANY-SPLIT, TC-EXP-OWN-WORK, TC-BACKDATE-NET, TC-REALDATE-CONSUME, TC-TIEBREAK, TC-EDIT-RECOMPUTE, TC-DELETE-RECOMPUTE.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
