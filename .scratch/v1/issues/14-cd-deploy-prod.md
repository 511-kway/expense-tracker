# CD: автодеплой на прод (этот VPS)

Status: needs-info
Blocked by: 02

Веха деплоя. Спека: `.scratch/v1/spec/01-architecture.md` (раздел 6).

## Что сделать
- Прод-стек на VPS: официальный self-hosted Supabase (docker compose) плюс контейнер статики фронта плюс Caddy (HTTPS, Let's Encrypt).
- GitHub Actions: после зелёных тестов на push в `main` джоба `deploy` заходит по SSH на VPS и выполняет скрипт деплоя: `git pull`, применить миграции к прод-базе, upsert владельца из `ADMIN_EMAIL`, собрать и выкатить фронт, перезапустить Edge Functions.
- Секреты только в GitHub Secrets и `.env` на сервере: SSH-ключ деплоя (отдельный пользователь `deploy`, ключ только для скрипта деплоя), ключи Supabase, Google OAuth.
- Self-hosted runner НЕ использовать: репозиторий публичный, чужие PR смогли бы выполнять код на сервере.
- `docs/deploy.md`: как любой ставит проект себе на сервер.

## Нужно от владельца
- Домен (A-запись на IP VPS). Без домена прод поднимается на IP без HTTPS и без Google-входа.
- Google OAuth client id/secret (инструкция будет в `docs/deploy.md`).

## Comments
