#!/usr/bin/env bash
# docker compose для прод-стека: upstream Supabase + наш docker-compose.prod.yml, окружение из
# supabase.env (постоянное) и .env (секреты). Любые аргументы compose: ./deploy/compose.sh ps
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
env_file="${DEPLOY_ENV_FILE:-$here/.env}"
if [[ ! -f "$env_file" ]]; then
  echo "Нет $env_file: cp deploy/.env.example deploy/.env && ./deploy/gen-secrets.sh" >&2
  exit 1
fi
exec docker compose \
  --project-directory "$here/supabase" \
  --env-file "$here/supabase.env" \
  --env-file "$env_file" \
  -f "$here/supabase/docker-compose.yml" \
  -f "$here/docker-compose.prod.yml" \
  "$@"
