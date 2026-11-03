# 1. Self-hosted Supabase на своём VPS

Статус: принято

## Контекст
Нужен Postgres (движок расчёта на plpgsql, транзакции), Google OAuth, хранилище файлов, авто-API. Только бесплатные open source инструменты, свой VPS и домен.

## Решение
Supabase self-hosted в Docker: Postgres, PostgREST, GoTrue (только Google), Storage, Edge Functions на Deno. Caddy + Let's Encrypt спереди. Node только как dev-сборка фронта (vite), не рантайм.

## Отклонённые варианты
- Pocketbase: SQLite, не подходит под требование Postgres и plpgsql-движок.
