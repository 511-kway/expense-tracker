# 21: CD: автодеплой на прод (этот VPS)

Status: needs-info
Blocked by: 04

Веха деплоя. Спека: `.scratch/v1/spec/01-architecture.md` (раздел 6).

## Что сделать
- [x] Прод-стек на VPS: официальный self-hosted Supabase (docker compose) плюс контейнер статики фронта плюс Caddy (HTTPS, Let's Encrypt). Подготовлен в `deploy/` (статику раздаёт тот же Caddy), проверен только офлайн.
- [ ] Прод-стек поднят на этом VPS и отвечает по HTTPS (ждёт домен и Google OAuth).
- [x] GitHub Actions: после зелёных тестов на push в `main` джоба `deploy` заходит по SSH на VPS и выполняет скрипт деплоя: `git pull`, применить миграции к прод-базе, upsert владельца из `ADMIN_EMAIL`, собрать и выкатить фронт, перезапустить Edge Functions. Джоба есть, пропускается без `DEPLOY_ENABLED=true`.
- [ ] Первый автодеплой прошёл зелёным.
- [x] Секреты только в GitHub Secrets и `.env` на сервере: SSH-ключ деплоя (отдельный пользователь `deploy`, ключ только для скрипта деплоя), ключи Supabase, Google OAuth. Подготовлено (`deploy/.env.example`, `deploy/gen-secrets.sh`, `scripts/server-setup.sh`), сами секреты не заведены.
- [x] Self-hosted runner НЕ использовать: репозиторий публичный, чужие PR смогли бы выполнять код на сервере.
- [x] `docs/deploy.md`: как любой ставит проект себе на сервер.

## Нужно от владельца
- Домен (A-запись на IP VPS). Без домена прод поднимается на IP без HTTPS и без Google-входа.
- Google OAuth client id/secret (инструкция будет в `docs/deploy.md`).

## Comments

2026-11-04, подготовка без запуска (на VPS ничего прод-ового не запущено, порты, пользователи и GitHub не тронуты):
- `deploy/supabase/` = upstream `docker/` на теге `self-hosted/v0.8.3` (коммит `bc27d266…`) без правок, `deploy/update-upstream.sh`. Наши отличия в `deploy/docker-compose.prod.yml`: наружу порты только у Caddy (80/443), шлюз Envoy на `127.0.0.1:8000`, Supavisor выключен (профиль), Studio только через SSH-туннель (Caddy проксирует лишь пути API); GoTrue только Google, email/телефон/аноним выключены, адреса из `DOMAIN`; данные в `DATA_DIR` (`/var/lib/expense-tracker`), вне checkout.
- Edge Functions: свой роутер `deploy/functions-main/index.ts` (upstream main + проверка JWT по функциям из `verify_jwt = false` в `config.toml`). Проверено в одноразовом контейнере edge-runtime v1.77.4 без портов: `claude_ingest` без JWT отвечает сама (`token_invalid`), `export` и `fetch_rates` получают 401 `UNAUTHORIZED_NO_AUTH_HEADER`.
- `scripts/deploy.sh`: ff-only pull и перезапуск новой версии, SHA из CI проверяется, сборка фронта в контейнере `node:24.22.1-alpine3.23` (и проверка, что dev-входа по email в сборке нет), `compose up --wait`, миграции psql по одной в транзакции с учётом в `supabase_migrations.schema_migrations` (поведение транзакции проверено на одноразовом Postgres), `allow-owner.sh`, атомарное переключение фронта, перезапуск функций, reload Caddy, проверки через Caddy с TLS (фронт, GoTrue, Google вкл/email выкл, PostgREST, функции).
- `scripts/server-setup.sh` (не запускался): пользователь `deploy` в группе docker, ключ `restrict,command=".../scripts/deploy.sh"`, каталог данных, `deploy/.env` через `deploy/gen-secrets.sh`, значения для GitHub, подсказка по firewall.
- CI: новая джоба `deploy-config` (shellcheck, `docker compose config` с проверкой, что `0.0.0.0` только у Caddy, `caddy validate`) и `deploy` (needs все тесты, `vars.DEPLOY_ENABLED == 'true'`, environment `production`, concurrency `deploy-production`, SSH с `DEPLOY_SSH_KEY`/`DEPLOY_HOST`/`DEPLOY_KNOWN_HOSTS`). Локально: actionlint, shellcheck, `docker compose config`, `caddy validate` зелёные.
- Не проверено вживую: полный подъём стека, выдача сертификата, вход через Google, применение наших миграций на чистом self-hosted Postgres (бакет `files` в `storage.buckets` требует, чтобы Storage успел создать свою схему; deploy.sh поэтому применяет миграции после `--wait`).
- Осталось для запуска (чек-лист в `docs/deploy.md`): купить домен и A-запись на IP VPS; Google OAuth client (origin `https://DOMAIN`, redirect `https://DOMAIN/auth/v1/callback`); ключ деплоя и `scripts/server-setup.sh` от root на отдельном checkout `/srv/expense-tracker`; firewall 22/80/443; вписать `DOMAIN`, `ACME_EMAIL`, `ADMIN_EMAIL`, `GOOGLE_CLIENT_ID/SECRET` в `deploy/.env`; первый деплой руками; в GitHub environment `production`, secrets `DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_KNOWN_HOSTS`, variable `DEPLOY_ENABLED=true`; push в `main`. После этого статус `done`.
