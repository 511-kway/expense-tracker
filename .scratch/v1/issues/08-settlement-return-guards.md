# Взаимозачёт, возврат аванса и проверки «до нуля» реплеем

Status: ready-for-agent
Blocked by: 05

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
- `settlement` обоих направлений (счёт опционален), `company_advance_return` (док 03, разделы 4.4, 4.6).
- Проверки «до нуля» внутри реплея по хронологии (ADR-0006), включая правки и удаления задним числом.

## Тесты
TC-SETTLE-IPAID, TC-SETTLE-CAP, TC-SETTLE-COMPANY-PAID, TC-ADV-RETURN, TC-ADV-RETURN-CAP, TC-BACKDATE-DELETE-GUARD, TC-BACKDATE-INSERT-GUARD.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
