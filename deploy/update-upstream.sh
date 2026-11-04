#!/usr/bin/env bash
# Вендоринг официального self-hosted Supabase (каталог docker/ репозитория supabase/supabase)
# в deploy/supabase/ на закреплённом релизе. Файлы кладутся без правок; всё своё лежит рядом
# (docker-compose.prod.yml, supabase.env, caddy/, functions-main/). Запускается вручную при
# обновлении Supabase, на сервере не нужен.
#
#   ./deploy/update-upstream.sh self-hosted/v0.8.3
#   git diff deploy/supabase   # прочитать изменения, сверить CHANGELOG релиза
#   diff deploy/supabase/volumes/functions/main/index.ts deploy/functions-main/index.ts
set -euo pipefail
cd "$(dirname "$0")"

tag="${1:?Укажите тег релиза, например self-hosted/v0.8.3}"
dest=supabase
base="https://raw.githubusercontent.com/supabase/supabase/refs/tags/${tag}"

# Только то, на что ссылается базовый docker-compose.yml (плюс лицензия Apache-2.0 и журнал версий).
files=(
  docker/docker-compose.yml
  docker/CHANGELOG.md
  docker/versions.md
  docker/volumes/api/envoy/envoy.yaml
  docker/volumes/api/envoy/cds.yaml
  docker/volumes/api/envoy/lds.template.yaml
  docker/volumes/api/envoy/docker-entrypoint.sh
  docker/volumes/db/realtime.sql
  docker/volumes/db/webhooks.sql
  docker/volumes/db/roles.sql
  docker/volumes/db/jwt.sql
  docker/volumes/db/_supabase.sql
  docker/volumes/db/logs.sql
  docker/volumes/db/pooler.sql
  docker/volumes/functions/main/index.ts
  docker/volumes/functions/deno.jsonc
  docker/volumes/pooler/pooler.exs
  LICENSE
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in "${files[@]}"; do
  out="$tmp/${f#docker/}"
  mkdir -p "$(dirname "$out")"
  curl -fsSL --retry 3 -o "$out" "$base/$f"
done

commit=$(curl -fsSL "https://api.github.com/repos/supabase/supabase/commits/${tag}" \
  | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)
printf 'repository=https://github.com/supabase/supabase\npath=docker\ntag=%s\ncommit=%s\n' \
  "$tag" "${commit:?не удалось узнать коммит тега}" > "$tmp/UPSTREAM"

rm -rf "$dest"
mv "$tmp" "$dest"
chmod 755 "$dest"
trap - EXIT
echo "deploy/supabase обновлён до $tag ($commit)."
