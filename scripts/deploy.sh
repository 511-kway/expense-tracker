#!/usr/bin/env bash
# Деплой на прод-сервере (docs/deploy.md). Запускает GitHub Actions по SSH (forced command
# пользователя deploy, в SSH_ORIGINAL_COMMAND приходит SHA коммита) или владелец руками:
#
#   ./scripts/deploy.sh            # выкатить origin/<DEPLOY_BRANCH> (по умолчанию main)
#   ./scripts/deploy.sh <sha>      # то же, но проверить, что <sha> входит в выкатываемую ветку
#
# Шаги: git pull --ff-only → сборка фронта (Node только в одноразовом контейнере) → сборка
# каталога функций → docker compose up --wait → миграции (psql, учёт в
# supabase_migrations.schema_migrations, как у Supabase CLI) → владелец из ADMIN_EMAIL →
# переключение фронта → перезапуск функций и Caddy → проверка здоровья. Любая ошибка = код != 0.
set -Eeuo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
deploy_dir="$repo/deploy"
build="$deploy_dir/.build"
env_file="$deploy_dir/.env"
node_image="node:24.22.1-alpine3.23"

step_name="подготовка"
step() {
  step_name="$*"
  printf '\n==> %s\n' "$*"
}
fail() {
  echo "ОШИБКА: $*" >&2
  exit 1
}
trap 'echo "ДЕПЛОЙ НЕ УДАЛСЯ на шаге «$step_name» (строка $LINENO)." >&2' ERR

compose() { "$deploy_dir/compose.sh" "$@"; }

# Значение из deploy/.env, иначе из deploy/supabase.env (как у compose: .env побеждает).
env_get() {
  local key="$1" file value=""
  for file in "$env_file" "$deploy_dir/supabase.env"; do
    value="$(sed -n "s/^$key=//p" "$file" | tail -n1)"
    value="${value%\"}"
    value="${value#\"}"
    [[ -n "$value" ]] && break
  done
  printf '%s' "$value"
}

# --- Аргумент: SHA из CI (SSH_ORIGINAL_COMMAND) или руками. Ничего другого не принимаем. ---
requested="${1:-${SSH_ORIGINAL_COMMAND:-}}"
if [[ -n "$requested" && ! "$requested" =~ ^[0-9a-f]{40}$ ]]; then
  fail "ожидался полный SHA коммита (40 hex) или ничего, получено: ${requested:0:80}"
fi

[[ -f "$env_file" ]] || fail "нет $env_file (cp deploy/.env.example deploy/.env && ./deploy/gen-secrets.sh)"
if [[ "$(stat -c %a "$env_file")" != "600" ]]; then
  echo "Предупреждение: у $env_file права $(stat -c %a "$env_file"), нужно 600 (chmod 600)." >&2
fi

mkdir -p "$build/web"

# Один деплой за раз. После git pull скрипт перезапускает сам себя (новая версия) и наследует
# дескриптор с уже взятой блокировкой.
if [[ -z "${DEPLOY_REEXEC:-}" ]]; then
  exec 9>"$build/deploy.lock"
  flock -w 900 9 || fail "другой деплой не закончился за 15 минут"
fi

branch="$(env_get DEPLOY_BRANCH)"
branch="${branch:-main}"

# --- 1. Код ---
step "git pull --ff-only origin $branch"
[[ "$(git symbolic-ref --short HEAD)" == "$branch" ]] || fail "checkout не на ветке $branch"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "в checkout есть локальные правки, деплой их не трогает"
before="$(git rev-parse HEAD)"
git fetch --prune origin "$branch"
git merge --ff-only "origin/$branch"
if [[ -z "${DEPLOY_REEXEC:-}" && "$(git rev-parse HEAD)" != "$before" ]]; then
  echo "Код обновлён, перезапускаю новую версию скрипта."
  DEPLOY_REEXEC=1 exec "$repo/scripts/deploy.sh" "$requested"
fi
if [[ -n "$requested" ]] && ! git merge-base --is-ancestor "$requested" HEAD; then
  fail "коммит $requested не входит в origin/$branch"
fi
sha="$(git rev-parse --short=12 HEAD)"
echo "Выкатываю $sha."

# --- 2. Окружение ---
step "проверка deploy/.env"
required=(DOMAIN ACME_EMAIL ADMIN_EMAIL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET POSTGRES_PASSWORD JWT_SECRET
  ANON_KEY SERVICE_ROLE_KEY DASHBOARD_USERNAME DASHBOARD_PASSWORD SECRET_KEY_BASE REALTIME_DB_ENC_KEY
  VAULT_ENC_KEY PG_META_CRYPTO_KEY S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET DATA_DIR)
missing=()
for key in "${required[@]}"; do
  [[ -n "$(env_get "$key")" ]] || missing+=("$key")
done
((${#missing[@]} == 0)) || fail "не заданы в deploy/.env: ${missing[*]}"
domain="$(env_get DOMAIN)"
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || fail "DOMAIN должен быть именем хоста без схемы и пути: $domain"
anon_key="$(env_get ANON_KEY)"
service_key="$(env_get SERVICE_ROLE_KEY)"
gw_port="$(env_get API_GW_HTTP_PORT)"
compose config --quiet

# --- 3. Фронт: собирается до того, как что-то трогаем в работающем стеке ---
step "сборка фронта ($node_image)"
web_out="$build/web/web-$sha"
if [[ -f "$web_out/index.html" ]]; then
  echo "Сборка $sha уже есть."
else
  web_tmp="$build/web/.tmp-$sha"
  rm -rf "$web_tmp"
  mkdir -p "$web_tmp"
  # Копия исходников внутри контейнера: в checkout не появляются node_modules и dist. .env*
  # удаляются, сборка берёт адрес и ключ только из окружения ниже. VITE_DEV_EMAIL_LOGIN нет.
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e VITE_SUPABASE_URL="https://$domain" -e VITE_SUPABASE_ANON_KEY="$anon_key" \
    -v "$repo/web:/src:ro" -v "$web_tmp:/out" "$node_image" sh -euc '
      cp -R /src /tmp/web
      cd /tmp/web
      rm -rf node_modules dist .env .env.*
      npm ci --no-audit --no-fund
      npm run build
      cp -R dist/. /out/'
  [[ -f "$web_tmp/index.html" ]] || fail "сборка фронта не дала index.html"
  # Вход по ссылке из письма только для vite dev (тикет 04): в сборке его быть не должно.
  if grep -rq "Mailpit" "$web_tmp"; then
    fail "в сборке фронта остался dev-вход по email"
  fi
  mv "$web_tmp" "$web_out"
fi

# --- 4. Edge Functions: main с проверкой JWT по функциям + функции проекта без тестов ---
step "сборка каталога функций"
fn_new="$build/functions.new"
rm -rf "$fn_new"
mkdir -p "$fn_new/main"
cp "$deploy_dir/functions-main/index.ts" "$fn_new/main/index.ts"
cp "$deploy_dir/supabase/volumes/functions/deno.jsonc" "$fn_new/deno.jsonc"
for dir in supabase/functions/*/; do
  name="$(basename "$dir")"
  [[ "$name" != "main" ]] || fail "имя функции main занято роутером edge runtime"
  cp -R "$dir" "$fn_new/$name"
done
find "$fn_new" -name '*_test.ts' -delete
# Функции с `verify_jwt = false` в supabase/config.toml (сейчас claude_ingest).
no_verify="$(awk '
  /^\[/ { fn = ""; if (match($0, /^\[functions\.[A-Za-z0-9_-]+\]/)) fn = substr($0, 12, RLENGTH - 12) }
  fn != "" && /^[[:space:]]*verify_jwt[[:space:]]*=[[:space:]]*false/ { print fn }
' supabase/config.toml)"
json="[]"
if [[ -n "$no_verify" ]]; then
  mapfile -t names <<<"$no_verify"
  json="$(printf '"%s",' "${names[@]}")"
  json="[${json%,}]"
fi
printf '%s\n' "$json" > "$fn_new/main/no_verify_jwt.json"
echo "Без проверки JWT: $json"

# --- 5. Стек ---
step "docker compose up --wait"
mkdir -p "$build/functions"
if [[ ! -e "$build/functions/main/index.ts" ]]; then
  # Первый запуск: функциям нужен каталог до старта контейнера.
  cp -R "$fn_new/." "$build/functions/"
fi
compose up -d --remove-orphans --wait --wait-timeout 600

# --- 6. Миграции ---
step "миграции"
psql_db() {
  compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -h localhost -U postgres -d postgres "$@"
}
psql_db <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text not null primary key,
  statements text[],
  name text
);
SQL
applied="$(psql_db -At -c 'select version from supabase_migrations.schema_migrations')"
count=0
for file in supabase/migrations/*.sql; do
  base="$(basename "$file" .sql)"
  version="${base%%_*}"
  name="${base#*_}"
  [[ "$version" =~ ^[0-9]{14}$ ]] || fail "имя миграции не по шаблону <14 цифр>_<имя>.sql: $file"
  if grep -qx "$version" <<<"$applied"; then
    continue
  fi
  echo "Применяю $base"
  # Файл и отметка о нём в одной транзакции: при ошибке не применится ни то, ни другое.
  {
    cat "$file"
    printf "\n;\ninsert into supabase_migrations.schema_migrations (version, name) values ('%s', '%s');\n" \
      "$version" "$name"
  } | psql_db --single-transaction -f -
  count=$((count + 1))
done
echo "Применено миграций: $count."
for version in $applied; do
  compgen -G "supabase/migrations/${version}_*.sql" >/dev/null ||
    echo "Предупреждение: миграция $version есть в базе, но не в репозитории." >&2
done
psql_db -c "notify pgrst, 'reload schema'"

# --- 7. Владелец ---
step "владелец из ADMIN_EMAIL"
SUPABASE_URL="http://127.0.0.1:${gw_port:-8000}" SUPABASE_SERVICE_ROLE_KEY="$service_key" \
  ADMIN_EMAIL="$(env_get ADMIN_EMAIL)" ./scripts/allow-owner.sh

# --- 8. Выкатка фронта и функций ---
step "переключение фронта на $sha, перезапуск функций и Caddy"
ln -sfn "web-$sha" "$build/web/current.new"
mv -Tf "$build/web/current.new" "$build/web/current"
find "$build/functions" -mindepth 1 -delete
cp -R "$fn_new/." "$build/functions/"
rm -rf "$fn_new"
compose restart functions
compose up -d --no-deps --wait --wait-timeout 120 functions
compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

# --- 9. Проверка снаружи через Caddy (настоящий TLS, имя резолвится на этот сервер) ---
step "проверка здоровья https://$domain"
check() {
  local what="$1" _
  shift
  for _ in $(seq 1 24); do
    if "$@"; then
      echo "ok: $what"
      return 0
    fi
    sleep 5
  done
  fail "проверка не прошла: $what"
}
https() { curl -sS --max-time 10 --resolve "$domain:443:127.0.0.1" -H "apikey: $anon_key" "$@" 2>/dev/null; }
frontend_served() { https "https://$domain/" | grep -q '<div id="root">'; }
auth_alive() { https -f -o /dev/null "https://$domain/auth/v1/health"; }
google_only() {
  local s
  s="$(https -f "https://$domain/auth/v1/settings")" &&
    grep -q '"google":true' <<<"$s" && grep -q '"email":false' <<<"$s" && grep -q '"phone":false' <<<"$s"
}
# app_users закрыта от клиента (тикет 04): живой PostgREST отвечает 401/403 (или 200 с пустым списком), не 5xx.
rest_alive() {
  [[ "$(https -o /dev/null -w '%{http_code}' "https://$domain/rest/v1/app_users?select=*&limit=1")" =~ ^(200|401|403)$ ]]
}
# Ответ самой функции (а не роутера edge runtime с 401 UNAUTHORIZED_*): проверка JWT для неё выключена.
ingest_without_jwt() {
  https -X POST -H 'Content-Type: application/json' -d '{}' "https://$domain/functions/v1/claude_ingest" |
    grep -q '"error":"token_invalid"'
}
export_needs_jwt() {
  [[ "$(https -o /dev/null -w '%{http_code}' -X POST "https://$domain/functions/v1/export")" == 401 ]]
}

check "фронт отдаётся" frontend_served
check "GoTrue жив" auth_alive
check "вход только через Google (email и телефон выключены)" google_only
check "PostgREST жив" rest_alive
check "claude_ingest без JWT, отвечает сама функция" ingest_without_jwt
check "export без JWT пользователя отклоняется" export_needs_jwt

# --- 10. Уборка: текущая сборка фронта и две предыдущие ---
step "уборка старых сборок"
mapfile -t old < <(find "$build/web" -mindepth 1 -maxdepth 1 -type d -name 'web-*' -printf '%T@ %p\n' |
  sort -rn | awk 'NR > 3 { print $2 }')
for dir in "${old[@]}"; do
  [[ "$dir" == "$web_out" ]] || rm -rf "$dir"
done
find "$build/web" -mindepth 1 -maxdepth 1 -name '.tmp-*' -exec rm -rf {} +

trap - ERR
echo
echo "Готово: $sha на https://$domain"
