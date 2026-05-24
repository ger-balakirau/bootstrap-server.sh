# Server Bootstrap Scripts

Набор скриптов для первичной настройки Linux-сервера и базового firewall.

## Быстрый старт

```bash
sudo nano scripts/bootstrap-server.conf
sudo bash scripts/bootstrap-server.sh
```

Все настройки находятся в `scripts/bootstrap-server.conf`, рядом со скриптом. Другой путь можно указать через `BOOTSTRAP_CONFIG_FILE`.

## Что делает основной скрипт

- обновляет пакеты;
- устанавливает базовые утилиты;
- настраивает timezone;
- создает административного пользователя с sudo-доступом;
- усиливает настройки SSH;
- настраивает firewall через `ufw`, `firewalld` или `nftables`;
- разрешает доверенные локальные CIDR-сети;
- опционально ставит и настраивает WireGuard в режиме сервера или клиента;
- опционально ставит и включает `fail2ban`;
- опционально выполняет reboot.

## Firewall

Основные переменные в `scripts/bootstrap-server.conf`:

```bash
FIREWALL_BACKEND="auto"
FIREWALL_ALLOW_SSH=true
FIREWALL_ALLOWED_TCP_PORTS=("80" "443")
FIREWALL_ALLOWED_UDP_PORTS=()
FIREWALL_ALLOW_TRUSTED_CIDRS=true
FIREWALL_TRUSTED_CIDRS=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
```

На Ubuntu режим `auto` выберет `ufw`. Скрипт сначала добавляет allow-правила, включая SSH, и только потом включает firewall.

## WireGuard

WireGuard настраивается в `scripts/bootstrap-server.conf`.

Отключить WireGuard:

```bash
INSTALL_WIREGUARD=false
WIREGUARD_MODE="server" # server или client
WIREGUARD_AUTO_UP=false
```

Включить режим сервера:

```bash
INSTALL_WIREGUARD=true
WIREGUARD_MODE="server"
WIREGUARD_SERVER_ADDRESS="10.8.0.1/24"
WIREGUARD_SERVER_LISTEN_PORT="51820"
WIREGUARD_SERVER_PEER_PUBLIC_KEY="client-public-key"
WIREGUARD_SERVER_PEER_PRESHARED_KEY="optional-preshared-key"
WIREGUARD_SERVER_PEER_ALLOWED_IPS=("10.8.0.2/32")
```

Включить режим клиента:

```bash
INSTALL_WIREGUARD=true
WIREGUARD_MODE="client"
WIREGUARD_CLIENT_ADDRESS="10.8.0.2/32"
WIREGUARD_PRIVATE_KEY="client-private-key"
WIREGUARD_CLIENT_SERVER_PUBLIC_KEY="server-public-key"
WIREGUARD_CLIENT_PRESHARED_KEY="optional-preshared-key"
WIREGUARD_CLIENT_ENDPOINT="vpn.example.com:51820"
WIREGUARD_CLIENT_ALLOWED_IPS=("10.8.0.0/24")
```

Если `WIREGUARD_PRIVATE_KEY` пустой, скрипт сгенерирует ключи сам и выведет public key в конце настройки WireGuard.

## Поддерживаемые системы

Скрипт рассчитан на Debian/Ubuntu и RHEL-подобные дистрибутивы с `apt`, `dnf` или `yum`.

## Безопасность запуска

По умолчанию firewall разрешает SSH-порт перед включением политик блокировки входящих соединений. Если сервер доступен только по нестандартному SSH-порту, сначала измените `SSH_PORT`.
