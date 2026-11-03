# Каркас репозитория: Supabase, тесты, CI

Status: in-progress
Blocked by: 01

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
- `supabase init`, конфиг под локальную разработку, `.env.example` с пустыми значениями (док 01, разделы 6, 10).
- Тестовый раннер pgTAP: `supabase/tests/`, общие фикстуры из док 06 раздел 2 (счета H1, H2, KS, KP, CASH; категории; тестовый allowed-пользователь) как SQL-хелперы.
- Хелпер `assert_invariants()` для инвариантов (док 06, раздел 13).
- GitHub Actions: поднять Supabase, `supabase db reset`, `supabase test db`.
- Один smoke-тест, что база поднимается.

## Готово, когда
- Тесты из списка ниже написаны (pgTAP, `supabase test db`) и зелёные; в каждом проверяются инварианты (док 06, раздел 13).
- Миграции применяются на чистую базу одной командой (`supabase db reset`).
- Нет денежной логики на клиенте, RLS на новых таблицах.

## Comments

- 2026-11-03: Supabase CLI 3.0.0, Postgres 17. `supabase init`, smoke-тест, CI (`.github/workflows/ci.yml`), `.env.example`, `scripts/dev-up.sh`, `docs/dev.md`. Фикстуры из док 06 и `assert_invariants()` переезжают в задачи 03 и 04: им нужны таблицы и представления.
- Найдено: CLI публикует порты на 0.0.0.0; на VPS это открывало базу и Studio в интернет. Исправлено сетью с `host_binding_ipv4=127.0.0.1` (скрипт dev-up) и `/etc/docker/daemon.json` `"ip": "127.0.0.1"`.
