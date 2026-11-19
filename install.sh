#!/bin/bash
# Основной naive-сервер на новом VPS. Старый сервер не трогает.
# Запуск от root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/shkaa/1node/main/install.sh)
# Логин и пароль вводятся в консоли. В git и в отдельный файл они не пишутся.
set -euo pipefail

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  die "Запускай от root."
fi
if [ ! -r /etc/os-release ]; then
  die "Не удалось определить ОС."
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) warn "Скрипт рассчитан на Debian/Ubuntu. Сейчас: ${ID:-unknown} ${VERSION_ID:-unknown}" ;;
esac

case "$(uname -m)" in
  x86_64) GO_ARCH="amd64" ;;
  aarch64|arm64) GO_ARCH="arm64" ;;
  *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
esac

if [ -f /etc/caddy/Caddyfile ] && grep -q "forward_proxy" /etc/caddy/Caddyfile; then
  die "Здесь уже есть naive. Скрипт останавливается, чтобы не затереть учётки. Это установка на новый VPS."
fi

for port in 80 443; do
  if ss -tln "( sport = :$port )" 2>/dev/null | tail -n +2 | grep -q .; then
    die "Порт $port уже занят. Освободи его и запусти скрипт снова."
  fi
done

if [ ! -t 0 ]; then
  die "Нужен интерактивный запуск: bash <(curl -fsSL https://raw.githubusercontent.com/shkaa/1node/main/install.sh)"
fi

DOMAIN="kakamba.work.gd"
while true; do
  read -r -p "Домен основного сервера [$DOMAIN]: " _v
  DOMAIN="${_v:-$DOMAIN}"
  [[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] && break
  warn "Домен выглядит некорректно."
done

while true; do
  read -r -p "Email для сертификата: " EMAIL
  [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
  warn "Email выглядит некорректно."
done

USERS_BLOCK=""
USER_LINKS=""
n=0
while true; do
  n=$((n + 1))
  while true; do
    read -r -p "Логин $n: " login
    [[ "$login" =~ ^[A-Za-z0-9_-]{1,32}$ ]] && break
    warn "Логин: латиница, цифры, _ и -, до 32 знаков."
  done
  while true; do
    read -r -s -p "Пароль $n: " pass
    echo
    read -r -s -p "Пароль $n ещё раз: " pass2
    echo
    if [ "$pass" != "$pass2" ]; then
      warn "Пароли не совпали."
      continue
    fi
    if [ "${#pass}" -lt 12 ] || [[ ! "$pass" =~ ^[A-Za-z0-9_-]+$ ]]; then
      warn "Пароль: от 12 знаков, латиница, цифры, _ и -."
      continue
    fi
    break
  done
  USERS_BLOCK="${USERS_BLOCK}    basic_auth ${login} ${pass}"$'\n'
  USER_LINKS="${USER_LINKS}naive+https://${login}:${pass}@${DOMAIN}:443"$'\n'
  read -r -p "Ещё учётка? [y/N]: " more
  [[ "$more" =~ ^[Yy]$ ]] || break
done
unset login pass pass2 more _v

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget openssl ca-certificates ufw iproute2 tar git

mem_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
swap_mb="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"
if [ "$mem_mb" -lt 1400 ] && [ "$swap_mb" -lt 512 ]; then
  log "Мало памяти, добавляю swap 2G для сборки."
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

cat > /etc/sysctl.d/99-naiveproxy-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null || true

ufw allow 22/tcp >/dev/null || true
ufw allow 80/tcp >/dev/null || true
ufw allow 443/tcp >/dev/null || true
ufw --force enable >/dev/null || true

log "Установка Go..."
go_version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
[[ "$go_version" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Не удалось получить версию Go."
go_tar="/tmp/${go_version}.linux-${GO_ARCH}.tar.gz"
wget -q "https://go.dev/dl/${go_version}.linux-${GO_ARCH}.tar.gz" -O "$go_tar"
rm -rf /usr/local/go
tar -C /usr/local -xzf "$go_tar"
rm -f "$go_tar"
export PATH="$PATH:/usr/local/go/bin:/root/go/bin"
go version

log "Сборка Caddy. Это несколько минут."
export TMPDIR=/root/tmp
mkdir -p /root/tmp /tmp/caddy-build
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
cd /tmp/caddy-build
rm -f caddy
export CGO_ENABLED=0
/root/go/bin/xcaddy build \
  --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
install -m 0755 /tmp/caddy-build/caddy /usr/bin/caddy
rm -rf /tmp/caddy-build
/usr/bin/caddy version

mkdir -p /var/www/html /etc/caddy
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Черновики</title>
<style>
  body { margin: 0; background: #f4f1ea; color: #24211c; font: 18px/1.55 Georgia, serif; }
  main { max-width: 640px; margin: 0 auto; padding: 48px 20px 64px; }
  h1 { font-weight: normal; font-size: 42px; margin: 0 0 12px; }
  p.lead { color: #5c564c; margin-top: 0; }
  article { border-top: 1px solid #ddd4c6; padding: 16px 0; }
  h2 { font-size: 22px; font-weight: normal; margin: 0 0 6px; }
  time { display: block; font: 12px/1.4 sans-serif; letter-spacing: .08em; text-transform: uppercase; color: #8a8174; margin-bottom: 8px; }
</style>
</head>
<body>
<main>
  <h1>Черновики</h1>
  <p class="lead">Короткие заметки, которые ещё не сложились в текст.</p>
  <article>
    <time>март</time>
    <h2>Про окно на кухне</h2>
    <p>Утром свет падает на стол узкой полосой. В этой полосе удобно оставлять одну страницу и не тащить за собой всю стопку.</p>
  </article>
  <article>
    <time>апрель</time>
    <h2>Список, который не растёт</h2>
    <p>Если пункт живёт в списке дольше месяца, я его вычёркиваю. Значит, он был не задачей, а настроением.</p>
  </article>
  <article>
    <time>май</time>
    <h2>Дождь и расписание</h2>
    <p>В дождь город становится короче: три маршрута вместо десяти. Этого хватает.</p>
  </article>
</main>
</body>
</html>
HTML

if [ -e /etc/caddy/Caddyfile ]; then
  cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d-%H%M%S)"
fi
umask 077
{
  cat << EOF
{
  order forward_proxy before file_server
  log {
    exclude http.log.error
  }
}

:443, ${DOMAIN} {
  tls ${EMAIL}
  encode
  forward_proxy {
EOF
  printf '%s' "$USERS_BLOCK"
  cat << 'EOF'
    hide_ip
    hide_via
    probe_resistance
  }
  file_server {
    root /var/www/html
  }
}
EOF
} > /etc/caddy/Caddyfile
chmod 600 /etc/caddy/Caddyfile
unset USERS_BLOCK

if [ -e /etc/systemd/system/caddy.service ]; then
  cp -a /etc/systemd/system/caddy.service "/etc/systemd/system/caddy.service.bak.$(date +%Y%m%d-%H%M%S)"
fi
cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy with NaiveProxy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

/usr/bin/caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || true)"
log "Сервер запущен."
echo
echo "A-запись ${DOMAIN} направь на ${IP:-адрес этого VPS}. Прокси облака выключи, иначе сертификат и клиент не сойдутся."
echo "Старый сервер не выключай, пока с этого VPS не откроется https://${DOMAIN}."
echo "Если перед ним стоит посредник, запусти на посреднике скрипт 2node ещё раз и укажи новый IP основного."
echo
echo "Ссылки для клиента. На диск они не записаны:"
printf '%s' "$USER_LINKS"
unset USER_LINKS
echo
echo "Журнал: journalctl -u caddy -f"
