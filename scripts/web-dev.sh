#!/usr/bin/env bash
# Фронт локально одной командой: ставит зависимости, берёт ключ из локального Supabase, запускает Vite на 127.0.0.1.
set -euo pipefail
cd "$(dirname "$0")/../web"

if ! supabase status >/dev/null 2>&1; then
  echo "Supabase не запущен, сначала ./scripts/dev-up.sh" >&2
  exit 1
fi

[ -d node_modules ] || npm ci

eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY)=')"
printf 'VITE_SUPABASE_URL=%s\nVITE_SUPABASE_ANON_KEY=%s\n' "$API_URL" "$ANON_KEY" > .env.local

exec npm run dev
