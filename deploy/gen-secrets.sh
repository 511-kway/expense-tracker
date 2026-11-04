#!/usr/bin/env bash
# Заполняет пустые секреты в deploy/.env (создаёт его из .env.example, если файла нет).
# Уже заданные значения не трогает, поэтому запускать повторно безопасно. Ключи ANON_KEY и
# SERVICE_ROLE_KEY подписываются JWT_SECRET (HS256, срок 10 лет) тем же способом, что
# upstream utils/generate-keys.sh. DOMAIN, ACME_EMAIL, ADMIN_EMAIL и Google вписываются руками.
#
#   ./deploy/gen-secrets.sh            # deploy/.env
#   ./deploy/gen-secrets.sh path/.env  # другой файл (например, для проверки)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
env_file="${1:-$here/.env}"

command -v openssl >/dev/null || { echo "Нужен openssl." >&2; exit 1; }

if [[ ! -f "$env_file" ]]; then
  (umask 077 && cp "$here/.env.example" "$env_file")
  echo "Создан $env_file из .env.example."
fi
chmod 600 "$env_file"

get() { sed -n "s/^$1=//p" "$env_file" | tail -n1; }

# Записать KEY=value, только если сейчас значение пустое (или строки нет).
fill() {
  local key="$1" value="$2"
  if [[ -n "$(get "$key")" ]]; then
    return 0
  fi
  local tmp
  tmp="$(mktemp "$env_file.XXXXXX")"
  if grep -q "^$key=" "$env_file"; then
    KEY="$key" VALUE="$value" awk 'BEGIN { k = ENVIRON["KEY"] "=" }
      index($0, k) == 1 && !done { print k ENVIRON["VALUE"]; done = 1; next } { print }' \
      "$env_file" > "$tmp"
  else
    cat "$env_file" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$env_file"
  echo "  $key сгенерирован"
}

b64url() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

jwt() {
  local role="$1" secret="$2" iat exp header payload signed
  iat=$(date +%s)
  exp=$((iat + 10 * 365 * 24 * 3600))
  header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' "$role" "$iat" "$exp" | b64url)
  signed="$header.$payload"
  printf '%s.%s' "$signed" "$(printf '%s' "$signed" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)"
}

echo "Секреты в $env_file:"

# Новый JWT_SECRET делает старые ключи недействительными: перевыпускаем их вместе с ним.
if [[ -z "$(get JWT_SECRET)" ]]; then
  if [[ -n "$(get ANON_KEY)$(get SERVICE_ROLE_KEY)" ]]; then
    echo "  JWT_SECRET пуст, а ключи заданы: перевыпускаю ANON_KEY и SERVICE_ROLE_KEY." >&2
  fi
  fill JWT_SECRET "$(openssl rand -hex 32)"
  for key in ANON_KEY SERVICE_ROLE_KEY; do
    sed -i "s/^$key=.*/$key=/" "$env_file"
  done
fi
secret="$(get JWT_SECRET)"
fill ANON_KEY "$(jwt anon "$secret")"
fill SERVICE_ROLE_KEY "$(jwt service_role "$secret")"

# hex: без символов, которые ломают postgres:// URL и sed в entrypoint шлюза.
fill POSTGRES_PASSWORD "$(openssl rand -hex 24)"
fill DASHBOARD_USERNAME "admin"
fill DASHBOARD_PASSWORD "$(openssl rand -hex 16)"
fill SECRET_KEY_BASE "$(openssl rand -hex 48)"
fill REALTIME_DB_ENC_KEY "$(openssl rand -hex 8)"
fill VAULT_ENC_KEY "$(openssl rand -hex 16)"
fill PG_META_CRYPTO_KEY "$(openssl rand -hex 24)"
fill S3_PROTOCOL_ACCESS_KEY_ID "$(openssl rand -hex 16)"
fill S3_PROTOCOL_ACCESS_KEY_SECRET "$(openssl rand -hex 32)"

missing=()
for key in DOMAIN ACME_EMAIL ADMIN_EMAIL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET; do
  [[ -n "$(get "$key")" ]] || missing+=("$key")
done
if ((${#missing[@]})); then
  echo "Впишите вручную: ${missing[*]} (см. docs/deploy.md)."
fi
echo "Важно: POSTGRES_PASSWORD применяется только при первом запуске базы; менять его потом"
echo "нужно в самой базе (upstream docker/utils/db-passwd.sh), а не только в .env."
