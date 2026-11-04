#!/usr/bin/env bash
# Владелец из ADMIN_EMAIL получает доступ: upsert в app_users с allowed = true (ADR-0007).
# SQL-сид не умеет читать env, поэтому это делает скрипт. Зовут dev-up.sh, db-reset.sh и деплой.
# Локально адрес API и service_role-ключ берутся из `supabase status`; на сервере задайте
# SUPABASE_URL и SUPABASE_SERVICE_ROLE_KEY в окружении.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${ADMIN_EMAIL:-}" && -f .env ]]; then
  ADMIN_EMAIL=$(sed -n 's/^ADMIN_EMAIL=//p' .env | tail -n1 | tr -d '"'"'"' \r')
fi
if [[ -z "${ADMIN_EMAIL:-}" ]]; then
  echo "ADMIN_EMAIL не задан (.env или окружение): владелец не добавлен, вход будет только в лист ожидания." >&2
  exit 1
fi

url="${SUPABASE_URL:-}"
key="${SUPABASE_SERVICE_ROLE_KEY:-}"
if [[ -z "$url" || -z "$key" ]]; then
  eval "$(supabase status -o env | grep -E '^(API_URL|SERVICE_ROLE_KEY)=')"
  url="$API_URL"
  key="$SERVICE_ROLE_KEY"
fi

body=$(printf '{"p_email":"%s"}' "$ADMIN_EMAIL")
# После сброса базы PostgREST перечитывает схему не мгновенно, поэтому несколько попыток.
for _ in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$url/rest/v1/rpc/allow_owner" \
    -H "apikey: $key" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "$body" || true)
  if [[ "$code" == 2* ]]; then
    echo "Владелец из ADMIN_EMAIL разрешён."
    exit 0
  fi
  sleep 1
done
echo "Не удалось разрешить владельца (HTTP $code)." >&2
exit 1
