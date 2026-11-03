# Комиссия за пополнение из своих денег

Status: ready-for-agent
Blocked by: 05

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
`company_topup` с `fee_payer = own` по ADR-0003: списание с остатка, сначала из своих (`own_avail` по реплею), нехватка из аванса, возмещение своей части сначала гасит `i_owe_company`, остаток в `company_owes_me`.

## Тесты
TC-TOPUP-FEE-OWN, TC-TOPUP-FEE-OWN-OFFSET, TC-TOPUP-FEE-OWN-SHORT.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments
