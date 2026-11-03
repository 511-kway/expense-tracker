# Установить Docker и Supabase CLI на машину разработки

Status: ready-for-human

Веха 1 (схема и движок). Спека: `.scratch/v1/spec/`, ADR: `docs/adr/`, термины: `GLOSSARY.md`.

## Что сделать
На этой машине нет Docker (проверено 2026-11-03), Node есть (v26). Без Docker локальный Supabase не поднять.

## Шаги
- Установить Docker Engine и docker compose plugin.
- Установить Supabase CLI (бинарник из GitHub releases или `npx supabase`).
- Проверка: `docker run hello-world` и `supabase --version` работают.

Это системная установка с правами root, поэтому за человеком (или агент по явному разрешению).

## Comments
