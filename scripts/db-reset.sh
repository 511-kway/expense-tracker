#!/usr/bin/env bash
# Чистая база из миграций и сидов плюс владелец из ADMIN_EMAIL (ADR-0007).
set -euo pipefail
cd "$(dirname "$0")/.."
supabase db reset "$@"
./scripts/allow-owner.sh
