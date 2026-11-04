#!/usr/bin/env bash
# Разовая подготовка прод-сервера (docs/deploy.md). Запускает владелец от root ОДИН раз, из уже
# склонированного репозитория:
#
#   git clone https://github.com/<you>/expense-tracker.git /srv/expense-tracker
#   sudo /srv/expense-tracker/scripts/server-setup.sh --pubkey ./deploy_key.pub [--host money.example.com]
#
# Что делает (повторный запуск безопасен):
# - проверяет Docker, compose >= 2.24 (нужны теги !override/!reset), git, curl, flock, openssl;
# - создаёт пользователя deploy в группе docker и отдаёт ему checkout;
# - кладёт ключ деплоя в ~deploy/.ssh/authorized_keys с forced command: этим ключом можно только
#   запустить scripts/deploy.sh (без shell, без проброса портов, без pty);
# - создаёт каталог данных и deploy/.env (секреты через deploy/gen-secrets.sh, права 600);
# - печатает значения для GitHub Secrets и подсказку по firewall (сам firewall не трогает).
set -euo pipefail

usage() {
  echo "Использование: $0 --pubkey <файл .pub или строка ключа> [--host <домен или IP для known_hosts>]" >&2
  exit 2
}

pubkey=""
host=""
while (($#)); do
  case "$1" in
    --pubkey) pubkey="${2:-}"; shift 2 ;;
    --host) host="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$pubkey" ]] || usage
[[ "$(id -u)" == 0 ]] || { echo "Запустите от root (sudo)." >&2; exit 1; }

repo="$(cd "$(dirname "$0")/.." && pwd)"
user=deploy

echo "==> Проверка инструментов"
for tool in docker git curl flock openssl awk ssh-keygen; do
  command -v "$tool" >/dev/null || { echo "Нет $tool. Установите и запустите снова." >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker не запущен (systemctl enable --now docker)." >&2; exit 1; }
compose_version="$(docker compose version --short 2>/dev/null || true)"
[[ -n "$compose_version" ]] || { echo "Нет плагина docker compose (пакет docker-compose-plugin)." >&2; exit 1; }
if ! printf '2.24.0\n%s\n' "${compose_version#v}" | sort -V -C; then
  echo "docker compose $compose_version слишком старый, нужен >= 2.24." >&2
  exit 1
fi
echo "Docker $(docker version --format '{{.Server.Version}}'), compose $compose_version."

echo "==> Ключ деплоя"
if [[ -f "$pubkey" ]]; then
  key_line="$(head -n1 "$pubkey")"
else
  key_line="$pubkey"
fi
tmp_key="$(mktemp)"
trap 'rm -f "$tmp_key"' EXIT
printf '%s\n' "$key_line" > "$tmp_key"
ssh-keygen -l -f "$tmp_key" >/dev/null 2>&1 || { echo "Это не публичный SSH-ключ: $key_line" >&2; exit 1; }
[[ "$key_line" != *PRIVATE* ]] || { echo "Нужен публичный ключ (.pub), не приватный." >&2; exit 1; }

echo "==> Пользователь $user"
if ! id "$user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$user"
  echo "Создан пользователь $user."
fi
# Группа docker = фактически root на этом сервере. Поэтому ключ ограничен одним скриптом.
usermod -aG docker "$user"
home="$(getent passwd "$user" | cut -d: -f6)"
install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
# restrict = no-port/agent/X11-forwarding, no-pty, no-user-rc. Команда клиента (SHA коммита)
# приходит в SSH_ORIGINAL_COMMAND, deploy.sh принимает только 40 hex.
printf 'restrict,command="%s/scripts/deploy.sh" %s\n' "$repo" "$key_line" > "$home/.ssh/authorized_keys"
chown "$user:$user" "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"

echo "==> Checkout $repo"
chown -R "$user:$user" "$repo"
branch="$(sed -n 's/^DEPLOY_BRANCH=//p' "$repo/deploy/.env" 2>/dev/null | tail -n1)"
branch="${branch:-main}"
su -s /bin/bash "$user" -c "cd '$repo' && git checkout -q '$branch' && git status -sb | head -n1"

echo "==> Каталог данных"
data_dir="$(sed -n 's/^DATA_DIR=//p' "$repo/deploy/.env" 2>/dev/null | tail -n1)"
data_dir="${data_dir:-$(sed -n 's/^DATA_DIR=//p' "$repo/deploy/supabase.env" | tail -n1)}"
install -d -m 750 "$data_dir"
echo "Данные Postgres и Storage: $data_dir (сюда же смотрят бэкапы, см. docs/deploy.md)."

echo "==> deploy/.env"
su -s /bin/bash "$user" -c "'$repo/deploy/gen-secrets.sh'"

echo
echo "==> GitHub (Settings → Environments → production и Settings → Secrets and variables → Actions)"
host="${host:-$(hostname -I | awk '{print $1}')}"
echo "Secret DEPLOY_HOST:        $host"
echo "Secret DEPLOY_KNOWN_HOSTS: (строки ниже целиком)"
for f in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
  [[ -f "$f" ]] && awk -v h="$host" '{ print h, $1, $2 }' "$f"
done
echo "Secret DEPLOY_SSH_KEY:     приватная половина ключа, который вы передали в --pubkey"
echo "Variable DEPLOY_ENABLED:   true (когда deploy/.env заполнен и первый ручной деплой прошёл)"

echo
echo "==> Firewall (скрипт его не меняет)"
echo "Снаружи должны быть открыты только 22, 80 и 443 (443/udp для HTTP/3). Например, ufw:"
echo "  ufw default deny incoming && ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443 && ufw enable"
echo "Docker публикует порты в обход ufw, поэтому в стеке наружу публикует порты только Caddy,"
echo "остальное на 127.0.0.1 или без портов. Проверка после деплоя: ss -tlnp | grep -v 127.0.0"
if command -v ufw >/dev/null; then
  ufw status | head -n1 || true
fi

echo
echo "Дальше: впишите DOMAIN, ACME_EMAIL, ADMIN_EMAIL, GOOGLE_CLIENT_ID/SECRET в $repo/deploy/.env"
echo "и выполните первый деплой руками: su - $user -c '$repo/scripts/deploy.sh'"
