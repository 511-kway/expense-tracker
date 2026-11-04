# Деплой на свой сервер

Прод-стек: официальный self-hosted Supabase (docker compose) + фронт как статика + Caddy с HTTPS от Let's Encrypt. Всё на одном VPS, один домен. Автодеплой: GitHub Actions после зелёных тестов заходит по SSH и запускает `scripts/deploy.sh`. Self-hosted runner не используется (репозиторий публичный, чужие PR не должны исполнять код на сервере).

Локальная разработка в `docs/dev.md`, этот документ только про прод.

## Как устроено

```
интернет ──► :80/:443 Caddy ──┬─ /auth/v1 /rest/v1 /storage/v1 /functions/v1 /realtime/v1 /graphql/v1
                              │        └─► api-gw (Envoy, 127.0.0.1:8000) ─► GoTrue, PostgREST, Storage,
                              │                                             Realtime, Edge Functions
                              └─ всё остальное ─► web/dist (deploy/.build/web/current)
SSH-туннель ──► 127.0.0.1:8000 /  ─► Studio (basic auth DASHBOARD_USERNAME / DASHBOARD_PASSWORD)
```

- Наружу публикует порты только Caddy (80, 443, 443/udp). Шлюз API слушает `127.0.0.1:8000`, Postgres, Studio, GoTrue и остальные без портов на хосте. Пулер Supavisor выключен (upstream публикует его на `0.0.0.0:5432/6543`). Docker публикует порты в обход ufw, поэтому это важно.
- Studio висит на корне шлюза. Caddy проксирует на шлюз только пути API, поэтому Studio снаружи не видно; открывается через SSH-туннель.
- Вход только через Google: в GoTrue выключены email, телефон и анонимный вход; site URL и redirect собираются из `DOMAIN`. Dev-вход по ссылке из письма (тикет 04) есть только в `vite dev`, `deploy.sh` дополнительно проверяет, что его нет в сборке.
- Edge Functions (`export`, `import_parse`, `fetch_rates`, `claude_ingest`) крутит edge runtime из upstream. JWT проверяется у всех функций, кроме тех, у кого в `supabase/config.toml` стоит `verify_jwt = false` (сейчас `claude_ingest`, вход по служебному токену). Upstream так не умеет (только глобальный `VERIFY_JWT`), поэтому роутер функций свой: `deploy/functions-main/index.ts` = upstream `main/index.ts` плюс две правки с пометкой `expense-tracker:`.

### Файлы

| Путь | Что это |
| --- | --- |
| `deploy/supabase/` | Официальный `docker/` из [supabase/supabase](https://github.com/supabase/supabase) на теге `self-hosted/v0.8.3` (коммит в `deploy/supabase/UPSTREAM`), без правок, лицензия Apache-2.0 в `deploy/supabase/LICENSE`. |
| `deploy/docker-compose.prod.yml` | Наши отличия поверх upstream: порты, Google, адреса из `DOMAIN`, данные в `DATA_DIR`, функции и фронт, Caddy. |
| `deploy/supabase.env` | Постоянные настройки Supabase (без секретов, в git). |
| `deploy/.env.example` → `deploy/.env` | Секреты и адрес сайта, только на сервере, права 600. |
| `deploy/gen-secrets.sh` | Заполняет пустые секреты в `deploy/.env` (JWT secret, anon/service_role ключи, пароль Postgres, Studio и прочие). Заданные не трогает. |
| `deploy/compose.sh` | `docker compose` с нужными файлами и окружением: `./deploy/compose.sh ps`, `./deploy/compose.sh logs -f auth`. |
| `deploy/caddy/Caddyfile` | HTTPS, статика, прокси API. |
| `deploy/functions-main/index.ts` | Роутер edge runtime с проверкой JWT по функциям. |
| `deploy/update-upstream.sh` | Перевендорить upstream на другой тег. |
| `scripts/deploy.sh` | Деплой (на сервере). |
| `scripts/server-setup.sh` | Разовая подготовка сервера (от root). |

Почему upstream лежит в репозитории, а не скачивается при деплое: деплой не зависит от GitHub raw и от того, что лежит в чужом теге; обновление Supabase видно как обычный diff в PR и проходит CI (`deploy-config`). Цена: около 200 КБ чужих файлов в репозитории.

## Поставить себе с нуля

Нужно: VPS с Linux (от 2 ГБ RAM, лучше 4), Docker Engine с плагином compose 2.24+, git, curl, openssl; домен или поддомен; аккаунт Google Cloud (бесплатно); свой форк этого репозитория, если нужен автодеплой.

1. **DNS.** A-запись домена (например, `money.example.com`) на IP сервера. Проверка: `dig +short money.example.com`.
2. **Google OAuth** (Google Cloud Console, <https://console.cloud.google.com>):
   1. Создать проект (или выбрать существующий).
   2. *APIs & Services → OAuth consent screen*: тип External, имя приложения, email поддержки; scopes `openid`, `email`, `profile` (верификация Google для них не нужна). Пока приложение в статусе Testing, войти могут только адреса из *Test users*: добавьте свой или нажмите *Publish app*.
   3. *APIs & Services → Credentials → Create credentials → OAuth client ID*, тип **Web application**:
      - Authorized JavaScript origins: `https://money.example.com`
      - Authorized redirect URIs: `https://money.example.com/auth/v1/callback`
   4. Скопировать Client ID и Client secret.
3. **Сервер.**
   ```bash
   # на своём компьютере: ключ, которым GitHub будет заходить на сервер (без пароля)
   ssh-keygen -t ed25519 -N '' -C deploy@expense-tracker -f deploy_key
   scp deploy_key.pub root@SERVER:/root/

   # на сервере, от root
   git clone https://github.com/<you>/expense-tracker.git /srv/expense-tracker
   /srv/expense-tracker/scripts/server-setup.sh --pubkey /root/deploy_key.pub --host money.example.com
   ```
   `server-setup.sh` проверит Docker, создаст пользователя `deploy` (группа docker, ключ только для `scripts/deploy.sh`), каталог данных `/var/lib/expense-tracker`, `deploy/.env` с секретами, и напечатает значения для GitHub и подсказку по firewall. Firewall он не трогает: откройте только 22, 80, 443 (пример команд ufw в выводе скрипта).
4. **`/srv/expense-tracker/deploy/.env`**: вписать `DOMAIN`, `ACME_EMAIL`, `ADMIN_EMAIL` (ваш Google-адрес: только его пустят внутрь, остальные попадут в лист ожидания, ADR-0007), `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`. Остальное уже сгенерировано. Описание каждой переменной в `deploy/.env.example`.
5. **Первый деплой руками** (покажет ошибки сразу):
   ```bash
   su - deploy -c /srv/expense-tracker/scripts/deploy.sh
   ```
   Первый раз качает образы и получает сертификат, это несколько минут. В конце `Готово: <коммит> на https://money.example.com`.
6. **Проверить**: открыть `https://money.example.com`, войти через Google. `ss -tlnp` на сервере: наружу (`0.0.0.0` / `[::]`) слушают только 22, 80, 443.
7. **Автодеплой.** В GitHub репозитория:
   - *Settings → Environments → New environment* `production` (по желанию: *Deployment branches* = `main`, *Required reviewers*).
   - *Settings → Secrets and variables → Actions → Secrets*: `DEPLOY_SSH_KEY` (содержимое приватного `deploy_key`), `DEPLOY_HOST` (домен или IP), `DEPLOY_KNOWN_HOSTS` (строки, которые напечатал `server-setup.sh`). Можно положить их в environment `production`, а не в репозиторий.
   - *Variables*: `DEPLOY_ENABLED` = `true`. Пока её нет, джоба `deploy` в CI пропускается.
   - Удалить `deploy_key` с компьютера (или убрать в менеджер паролей).

С этого момента каждый push в `main` после зелёных `db-tests`, `web`, `edge-functions`, `deploy-config` выкатывается сам. Деплои идут по одному (concurrency group `deploy-production`, плюс `flock` на сервере).

## Что делает `scripts/deploy.sh`

1. `git fetch` + `git merge --ff-only origin/main` (ветка из `DEPLOY_BRANCH`). Локальные правки в checkout = ошибка. Если код обновился, скрипт перезапускает уже новую версию себя. SHA из CI должен входить в ветку, любой другой аргумент отвергается.
2. Проверяет, что в `deploy/.env` заданы все обязательные переменные, и `docker compose config`.
3. Собирает фронт в одноразовом контейнере `node:24.22.1-alpine3.23` (Node только на время сборки, на сервере его нет) с `VITE_SUPABASE_URL=https://DOMAIN` и `VITE_SUPABASE_ANON_KEY` в `deploy/.build/web/web-<коммит>`. Работающий сайт пока не тронут. Решение собирать на сервере, а не в CI: forced-command ключ не умеет принимать файлы, а сборка стоит ~1 минуту.
4. Собирает каталог функций: роутер `deploy/functions-main`, функции из `supabase/functions` без `*_test.ts`, список функций без JWT из `supabase/config.toml`.
5. `docker compose up -d --wait`: поднимает или обновляет контейнеры и ждёт healthcheck.
6. **Миграции.** Каждый файл `supabase/migrations/<версия>_<имя>.sql`, которого нет в `supabase_migrations.schema_migrations`, применяется через `psql --single-transaction` от роли `postgres` (как у Supabase CLI), вместе с записью о нём в той же транзакции: упавшая миграция не применится и не отметится. Таблица учёта та же, что у CLI, поэтому `supabase migration list --db-url ...` через туннель покажет то же самое. Повторный запуск ничего не делает. Потом `notify pgrst, 'reload schema'`.
7. Владелец из `ADMIN_EMAIL`: `scripts/allow-owner.sh` через шлюз на 127.0.0.1 ключом service_role.
8. Атомарно переключает `deploy/.build/web/current` на новую сборку, обновляет функции и перезапускает edge runtime, перечитывает Caddyfile.
9. Проверка через Caddy с настоящим TLS: фронт отдаётся; GoTrue жив и в `/auth/v1/settings` Google включён, email и телефон выключены; PostgREST отвечает; `claude_ingest` отвечает сам (без JWT); `export` без JWT получает 401.
10. Оставляет текущую и две предыдущие сборки фронта.

Любая ошибка = ненулевой код выхода и красная джоба в Actions. Отката нет: миграции вперёд-only. Если упала проверка после переключения, фронт уже новый; вернуть старую сборку руками: `ln -sfn web-<старый> deploy/.build/web/current` (список в `deploy/.build/web/`).

## Обслуживание

```bash
cd /srv/expense-tracker
./deploy/compose.sh ps                 # состояние
./deploy/compose.sh logs -f auth       # логи GoTrue (functions, rest, storage, caddy, db ...)
./deploy/compose.sh exec db psql -U postgres -h localhost   # psql в прод-базу
```

**Studio** через SSH-туннель: `ssh -L 8000:127.0.0.1:8000 root@SERVER`, затем <http://localhost:8000>, логин и пароль `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` из `deploy/.env`. Там же лист ожидания: Table Editor → `app_users`.

**Данные** лежат вне checkout: `DATA_DIR` (по умолчанию `/var/lib/expense-tracker`: `db/` Postgres, `storage/` файлы Storage), ключ pgsodium в docker volume `expense-tracker_db-config`. Не меняйте `POSTGRES_PASSWORD` в `.env` после первого запуска: он задаётся базе только при инициализации.

**Бэкапы** пока не настроены: задача в `.scratch/backups/` (ночной `pg_dump` + архив Storage, шифрование, вне VPS). До неё руками:
```bash
./deploy/compose.sh exec -T db pg_dump -U postgres -h localhost -Fc postgres > backup-$(date +%F).dump
tar -czf storage-$(date +%F).tgz -C /var/lib/expense-tracker storage
```

**Обновить Supabase**: `./deploy/update-upstream.sh self-hosted/vX.Y.Z` на своей машине, прочитать `git diff deploy/supabase` и `deploy/supabase/CHANGELOG.md`, сверить `deploy/supabase/volumes/functions/main/index.ts` с `deploy/functions-main/index.ts` (перенести правки upstream, оставить две свои), PR. Деплой подхватит новые образы сам. Перед обновлением сделать бэкап.

## Чек-лист запуска для владельца этого репозитория

Сделано в тикете 21 (без запуска): всё в `deploy/`, `scripts/deploy.sh`, `scripts/server-setup.sh`, джоба `deploy` в CI (пропускается без `DEPLOY_ENABLED`). На этом VPS ничего прод-ового не запущено и не открыто.

- [ ] Купить домен, A-запись на IP этого VPS.
- [ ] Google OAuth client для домена (раздел «Поставить себе с нуля», шаг 2): origin `https://DOMAIN`, redirect `https://DOMAIN/auth/v1/callback`. Локальный client с redirect `http://localhost:54321/auth/v1/callback` (docs/dev.md) не трогать, для прода отдельный или добавить URI в тот же.
- [ ] Ключ деплоя (`ssh-keygen`, шаг 3), `scripts/server-setup.sh --pubkey ... --host DOMAIN` от root. Checkout для прода отдельный (`/srv/expense-tracker`), не рабочая папка разработки.
- [ ] Firewall: только 22, 80, 443. Локальный dev-стек слушает только 127.0.0.1, ему порты не нужны.
- [ ] Порты 80/443 и 127.0.0.1:8000 на VPS свободны (`ss -tlnp`); если 8000 занят, `API_GW_HTTP_PORT` в `deploy/.env`.
- [ ] `deploy/.env`: `DOMAIN`, `ACME_EMAIL`, `ADMIN_EMAIL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`.
- [ ] Первый деплой руками: `su - deploy -c /srv/expense-tracker/scripts/deploy.sh`, вход через Google, `ss -tlnp`.
- [ ] GitHub: environment `production`, secrets `DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_KNOWN_HOSTS`, variable `DEPLOY_ENABLED=true`.
- [ ] Push в `main` и зелёная джоба `deploy`.
- [ ] Выпустить токен Claude Code на проде («Настройки»), в `docs/claude-code-ingest.md` адрес `https://DOMAIN/functions/v1/claude_ingest`.
- [ ] Бэкапы (`.scratch/backups/`).

## Если что-то не так

- **Сертификат не выдаётся**: `./deploy/compose.sh logs caddy`. Обычно A-запись ещё не обновилась или 80/443 закрыты снаружи.
- **Google: `redirect_uri_mismatch`**: в Google Console redirect должен быть ровно `https://DOMAIN/auth/v1/callback`.
- **Вход проходит, но лист ожидания**: `ADMIN_EMAIL` не совпадает с Google-адресом; поправить `.env` и перезапустить деплой.
- **Функция 401 `UNAUTHORIZED_*`**: это роутер edge runtime (нет JWT пользователя). Для `claude_ingest` так быть не должно: проверьте `deploy/.build/functions/main/no_verify_jwt.json` и `./deploy/compose.sh logs functions` (строка `JWT verification off for: claude_ingest`).
