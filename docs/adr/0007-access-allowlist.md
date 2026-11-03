# 7. Доступ: Google-вход плюс таблица app_users с флагом allowed

Статус: принято (2026-11-03).

## Решение
- Вход только через Google (GoTrue). Пользователь один, семьи нет: данные по-прежнему по `user_id = auth.uid()`.
- Таблица `app_users`: `email` (unique), `user_id` (null до первого входа), `name`, `allowed boolean default false`, `first_seen_at`, `last_attempt_at`, `attempts`.
- Email владельца задаётся в `.env` как `ADMIN_EMAIL` (не в репозитории: проект публичный, любой ставит себе со своим email). Скрипт деплоя и локальный `db reset` делают upsert этой строки с `allowed = true`.
- После входа фронт зовёт RPC `register_login()`: upsert по email из JWT, привязка `user_id`, `attempts += 1`. Возвращает `allowed`. Если `false`, фронт показывает «Добавили вас в лист ожидания» и делает sign out.
- Функция `is_allowed()` (по `auth.uid()` → `app_users.allowed`). Все RLS-политики пользовательских таблиц: `user_id = auth.uid() AND is_allowed()`. Денежные RPC проверяют `is_allowed()` первым шагом (ошибка `not_allowed`).
- Включить доступ: руками `allowed = true` в Supabase Studio. UI админки нет.
