#!/usr/bin/env bash
# Поднять локальный Supabase так, чтобы порты слушали только 127.0.0.1.
# Supabase CLI создаёт свою docker-сеть и по умолчанию публикует порты на 0.0.0.0,
# то есть на VPS база (пароль postgres) и Studio торчат в интернет.
# Если сеть уже существует, CLI её переиспользует, поэтому создаём её заранее.
set -euo pipefail
cd "$(dirname "$0")/.."

project_id=$(sed -n 's/^project_id *= *"\(.*\)"/\1/p' supabase/config.toml)
net="supabase_network_${project_id}"

binding=$(docker network inspect "$net" \
  --format '{{index .Options "com.docker.network.bridge.host_binding_ipv4"}}' 2>/dev/null || true)

if [[ "$binding" != "127.0.0.1" ]]; then
  supabase stop >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  docker network create -o com.docker.network.bridge.host_binding_ipv4=127.0.0.1 "$net" >/dev/null
fi

supabase start "$@"

if ss -tln | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\[::\]):543' >/dev/null; then
  echo "ОШИБКА: порты Supabase открыты наружу, останавливаю." >&2
  supabase stop
  exit 1
fi
echo "Supabase слушает только 127.0.0.1."
