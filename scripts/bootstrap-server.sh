#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Toggleable configuration
###############################################################################

RUN_SYSTEM_UPDATE=true
INSTALL_BASE_PACKAGES=true
CONFIGURE_TIMEZONE=true
CREATE_ADMIN_USER=false
CONFIGURE_SSH=true
CONFIGURE_FIREWALL=true
INSTALL_WIREGUARD=false
INSTALL_FAIL2BAN=true
AUTO_REBOOT=false

TIMEZONE="Europe/Moscow"

ADMIN_USER="deploy"
ADMIN_SSH_PUBLIC_KEY=""
ADMIN_PASSWORDLESS_SUDO=false

SSH_PORT="22"
SSH_DISABLE_ROOT_LOGIN=true
SSH_DISABLE_PASSWORD_AUTH=true

# Firewall backend: auto, ufw, firewalld, nftables
FIREWALL_BACKEND="auto"
FIREWALL_ALLOW_SSH=true
FIREWALL_ALLOWED_TCP_PORTS=("80" "443")
FIREWALL_ALLOWED_UDP_PORTS=()
FIREWALL_ALLOW_TRUSTED_CIDRS=true
FIREWALL_TRUSTED_CIDRS=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")

# WireGuard mode: server or client
WIREGUARD_MODE="server"
WIREGUARD_INTERFACE="wg0"
WIREGUARD_PORT="51820"
WIREGUARD_CONFIG_DIR="/etc/wireguard"
WIREGUARD_PRIVATE_KEY=""
WIREGUARD_DNS=("1.1.1.1" "8.8.8.8")

# Server mode settings
WIREGUARD_SERVER_ADDRESS="10.8.0.1/24"
WIREGUARD_SERVER_LISTEN_PORT="${WIREGUARD_PORT}"
WIREGUARD_SERVER_ENABLE_NAT=true
WIREGUARD_SERVER_NAT_INTERFACE="" # empty means auto-detect default route interface
WIREGUARD_SERVER_PEER_PUBLIC_KEY=""
WIREGUARD_SERVER_PEER_ALLOWED_IPS=("10.8.0.2/32")

# Client mode settings
WIREGUARD_CLIENT_ADDRESS="10.8.0.2/32"
WIREGUARD_CLIENT_SERVER_PUBLIC_KEY=""
WIREGUARD_CLIENT_ENDPOINT="vpn.example.com:${WIREGUARD_PORT}"
WIREGUARD_CLIENT_ALLOWED_IPS=("10.8.0.0/24")
WIREGUARD_CLIENT_PERSISTENT_KEEPALIVE="25"
WIREGUARD_AUTO_UP=false

BASE_PACKAGES_DEBIAN=(
  ca-certificates
  curl
  gnupg
  iptables
  lsb-release
  openssh-server
  software-properties-common
  sudo
  unattended-upgrades
  vim
  wget
)

BASE_PACKAGES_RHEL=(
  ca-certificates
  curl
  gnupg2
  iptables
  openssh-server
  sudo
  vim
  wget
)

###############################################################################
# Helpers
###############################################################################

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

as_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root: sudo bash $0"
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    die "Supported package manager not found: apt-get, dnf or yum"
  fi
}

install_packages() {
  local packages=("$@")

  case "${PKG_MANAGER}" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
  esac
}

enable_service() {
  local service="$1"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now "${service}"
  else
    service "${service}" start
  fi
}

restart_service() {
  local service="$1"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "${service}"
  else
    service "${service}" restart
  fi
}

join_by() {
  local separator="$1"
  shift

  if [[ "$#" -eq 0 ]]; then
    return 0
  fi

  local first="$1"
  shift || true

  printf '%s' "${first}"
  printf '%s' "${@/#/${separator}}"
}

ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    printf 'ssh'
  else
    printf 'sshd'
  fi
}

default_route_interface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

###############################################################################
# Setup steps
###############################################################################

system_update() {
  log "Updating package metadata and installed packages"

  case "${PKG_MANAGER}" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      ;;
    dnf)
      dnf upgrade -y
      ;;
    yum)
      yum update -y
      ;;
  esac
}

install_base_packages() {
  log "Installing base packages"

  case "${PKG_MANAGER}" in
    apt)
      install_packages "${BASE_PACKAGES_DEBIAN[@]}"
      ;;
    dnf|yum)
      install_packages "${BASE_PACKAGES_RHEL[@]}"
      ;;
  esac
}

configure_timezone() {
  log "Setting timezone to ${TIMEZONE}"
  timedatectl set-timezone "${TIMEZONE}"
}

create_admin_user() {
  log "Creating admin user ${ADMIN_USER}"

  if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "${ADMIN_USER}"
  fi

  usermod -aG sudo "${ADMIN_USER}" 2>/dev/null || usermod -aG wheel "${ADMIN_USER}"

  if [[ -n "${ADMIN_SSH_PUBLIC_KEY}" ]]; then
    install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
    printf '%s\n' "${ADMIN_SSH_PUBLIC_KEY}" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
  fi

  if [[ "${ADMIN_PASSWORDLESS_SUDO}" == "true" ]]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${ADMIN_USER}" > "/etc/sudoers.d/90-${ADMIN_USER}"
    chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}"
    visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}" >/dev/null
  fi
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "${file}"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" "${file}"
  else
    printf '\n%s %s\n' "${key}" "${value}" >> "${file}"
  fi
}

configure_ssh() {
  log "Configuring SSH"

  set_sshd_option "Port" "${SSH_PORT}"

  if [[ "${SSH_DISABLE_ROOT_LOGIN}" == "true" ]]; then
    set_sshd_option "PermitRootLogin" "no"
  fi

  if [[ "${SSH_DISABLE_PASSWORD_AUTH}" == "true" ]]; then
    set_sshd_option "PasswordAuthentication" "no"
    set_sshd_option "KbdInteractiveAuthentication" "no"
  fi

  sshd -t
  restart_service "$(ssh_service_name)"
}

detect_firewall_backend() {
  case "${FIREWALL_BACKEND}" in
    auto)
      if command -v ufw >/dev/null 2>&1 || [[ "${PKG_MANAGER}" == "apt" ]]; then
        printf 'ufw'
      elif command -v firewall-cmd >/dev/null 2>&1; then
        printf 'firewalld'
      else
        printf 'nftables'
      fi
      ;;
    ufw|firewalld|nftables)
      printf '%s' "${FIREWALL_BACKEND}"
      ;;
    *)
      die "Unsupported FIREWALL_BACKEND=${FIREWALL_BACKEND}"
      ;;
  esac
}

configure_firewall_ufw() {
  log "Configuring ufw"
  command -v ufw >/dev/null 2>&1 || install_packages ufw

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  if [[ "${FIREWALL_ALLOW_SSH}" == "true" ]]; then
    ufw allow "${SSH_PORT}/tcp"
  fi

  if [[ "${FIREWALL_ALLOW_TRUSTED_CIDRS}" == "true" ]]; then
    for cidr in "${FIREWALL_TRUSTED_CIDRS[@]}"; do
      ufw allow from "${cidr}"
    done
  fi

  for port in "${FIREWALL_ALLOWED_TCP_PORTS[@]}"; do
    ufw allow "${port}/tcp"
  done

  for port in "${FIREWALL_ALLOWED_UDP_PORTS[@]}"; do
    ufw allow "${port}/udp"
  done

  if [[ "${INSTALL_WIREGUARD}" == "true" && "${WIREGUARD_MODE}" == "server" ]]; then
    ufw allow "${WIREGUARD_SERVER_LISTEN_PORT}/udp"
  fi

  ufw --force enable
  ufw status verbose
}

configure_firewall_firewalld() {
  log "Configuring firewalld"
  command -v firewall-cmd >/dev/null 2>&1 || install_packages firewalld
  enable_service firewalld

  if [[ "${FIREWALL_ALLOW_SSH}" == "true" ]]; then
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
  fi

  if [[ "${FIREWALL_ALLOW_TRUSTED_CIDRS}" == "true" ]]; then
    for cidr in "${FIREWALL_TRUSTED_CIDRS[@]}"; do
      firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${cidr} accept"
    done
  fi

  for port in "${FIREWALL_ALLOWED_TCP_PORTS[@]}"; do
    firewall-cmd --permanent --add-port="${port}/tcp"
  done

  for port in "${FIREWALL_ALLOWED_UDP_PORTS[@]}"; do
    firewall-cmd --permanent --add-port="${port}/udp"
  done

  if [[ "${INSTALL_WIREGUARD}" == "true" && "${WIREGUARD_MODE}" == "server" ]]; then
    firewall-cmd --permanent --add-port="${WIREGUARD_SERVER_LISTEN_PORT}/udp"
  fi

  firewall-cmd --reload
  firewall-cmd --list-all
}

configure_firewall_nftables() {
  log "Configuring nftables"
  command -v nft >/dev/null 2>&1 || install_packages nftables

  local tcp_ports=()
  local udp_ports=()

  if [[ "${FIREWALL_ALLOW_SSH}" == "true" ]]; then
    tcp_ports+=("${SSH_PORT}")
  fi

  tcp_ports+=("${FIREWALL_ALLOWED_TCP_PORTS[@]}")
  udp_ports+=("${FIREWALL_ALLOWED_UDP_PORTS[@]}")

  if [[ "${INSTALL_WIREGUARD}" == "true" && "${WIREGUARD_MODE}" == "server" ]]; then
    udp_ports+=("${WIREGUARD_SERVER_LISTEN_PORT}")
  fi

  {
    printf 'flush ruleset\n'
    printf 'table inet filter {\n'
    printf '  chain input {\n'
    printf '    type filter hook input priority 0; policy drop;\n'
    printf '    iif lo accept\n'
    printf '    ct state established,related accept\n'
    printf '    ip protocol icmp accept\n'
    printf '    ip6 nexthdr icmpv6 accept\n'
    if [[ "${#tcp_ports[@]}" -gt 0 ]]; then
      printf '    tcp dport { %s } accept\n' "$(IFS=,; printf '%s' "${tcp_ports[*]}")"
    fi
    if [[ "${#udp_ports[@]}" -gt 0 ]]; then
      printf '    udp dport { %s } accept\n' "$(IFS=,; printf '%s' "${udp_ports[*]}")"
    fi
    if [[ "${FIREWALL_ALLOW_TRUSTED_CIDRS}" == "true" ]]; then
      for cidr in "${FIREWALL_TRUSTED_CIDRS[@]}"; do
        printf '    ip saddr %s accept\n' "${cidr}"
      done
    fi
    printf '  }\n'
    printf '  chain forward {\n'
    printf '    type filter hook forward priority 0; policy drop;\n'
    printf '  }\n'
    printf '  chain output {\n'
    printf '    type filter hook output priority 0; policy accept;\n'
    printf '  }\n'
    printf '}\n'
  } > /etc/nftables.conf

  nft -f /etc/nftables.conf
  enable_service nftables
  nft list ruleset
}

configure_firewall() {
  local backend
  backend="$(detect_firewall_backend)"

  case "${backend}" in
    ufw)
      configure_firewall_ufw
      ;;
    firewalld)
      configure_firewall_firewalld
      ;;
    nftables)
      configure_firewall_nftables
      ;;
  esac
}

wireguard_private_key_path() {
  printf '%s/%s.private.key' "${WIREGUARD_CONFIG_DIR}" "${WIREGUARD_INTERFACE}"
}

wireguard_public_key_path() {
  printf '%s/%s.public.key' "${WIREGUARD_CONFIG_DIR}" "${WIREGUARD_INTERFACE}"
}

wireguard_config_path() {
  printf '%s/%s.conf' "${WIREGUARD_CONFIG_DIR}" "${WIREGUARD_INTERFACE}"
}

get_wireguard_private_key() {
  local private_key_path
  local public_key_path
  private_key_path="$(wireguard_private_key_path)"
  public_key_path="$(wireguard_public_key_path)"

  if [[ -n "${WIREGUARD_PRIVATE_KEY}" ]]; then
    printf '%s\n' "${WIREGUARD_PRIVATE_KEY}" > "${private_key_path}"
  elif [[ ! -s "${private_key_path}" ]]; then
    wg genkey > "${private_key_path}"
  fi

  chmod 600 "${private_key_path}"
  wg pubkey < "${private_key_path}" > "${public_key_path}"
  chmod 644 "${public_key_path}"
  cat "${private_key_path}"
}

install_wireguard_packages() {
  log "Installing WireGuard packages"

  case "${PKG_MANAGER}" in
    apt)
      install_packages wireguard
      ;;
    dnf|yum)
      install_packages wireguard-tools
      ;;
  esac
}

configure_wireguard_ip_forwarding() {
  log "Enabling IPv4 forwarding for WireGuard"
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wireguard-forward.conf
  sysctl --system >/dev/null
}

write_wireguard_server_config() {
  local config_path
  local private_key
  local nat_interface
  config_path="$(wireguard_config_path)"
  private_key="$(get_wireguard_private_key)"
  nat_interface="${WIREGUARD_SERVER_NAT_INTERFACE}"

  if [[ -z "${nat_interface}" ]]; then
    nat_interface="$(default_route_interface)"
  fi

  {
    printf '[Interface]\n'
    printf 'Address = %s\n' "${WIREGUARD_SERVER_ADDRESS}"
    printf 'ListenPort = %s\n' "${WIREGUARD_SERVER_LISTEN_PORT}"
    printf 'PrivateKey = %s\n' "${private_key}"

    if [[ "${WIREGUARD_SERVER_ENABLE_NAT}" == "true" && -n "${nat_interface}" ]]; then
      printf 'PostUp = iptables -A FORWARD -i %%i -j ACCEPT; iptables -A FORWARD -o %%i -j ACCEPT; iptables -t nat -A POSTROUTING -o %s -j MASQUERADE\n' "${nat_interface}"
      printf 'PostDown = iptables -D FORWARD -i %%i -j ACCEPT; iptables -D FORWARD -o %%i -j ACCEPT; iptables -t nat -D POSTROUTING -o %s -j MASQUERADE\n' "${nat_interface}"
    fi

    if [[ -n "${WIREGUARD_SERVER_PEER_PUBLIC_KEY}" ]]; then
      printf '\n[Peer]\n'
      printf 'PublicKey = %s\n' "${WIREGUARD_SERVER_PEER_PUBLIC_KEY}"
      printf 'AllowedIPs = %s\n' "$(join_by ', ' "${WIREGUARD_SERVER_PEER_ALLOWED_IPS[@]}")"
    fi
  } > "${config_path}"

  chmod 600 "${config_path}"
}

write_wireguard_client_config() {
  local config_path
  local private_key
  config_path="$(wireguard_config_path)"
  private_key="$(get_wireguard_private_key)"

  [[ -n "${WIREGUARD_CLIENT_SERVER_PUBLIC_KEY}" ]] || die "WIREGUARD_CLIENT_SERVER_PUBLIC_KEY is required for WireGuard client mode"
  [[ -n "${WIREGUARD_CLIENT_ENDPOINT}" ]] || die "WIREGUARD_CLIENT_ENDPOINT is required for WireGuard client mode"

  {
    printf '[Interface]\n'
    printf 'Address = %s\n' "${WIREGUARD_CLIENT_ADDRESS}"
    printf 'PrivateKey = %s\n' "${private_key}"

    if [[ "${#WIREGUARD_DNS[@]}" -gt 0 ]]; then
      printf 'DNS = %s\n' "$(join_by ', ' "${WIREGUARD_DNS[@]}")"
    fi

    printf '\n[Peer]\n'
    printf 'PublicKey = %s\n' "${WIREGUARD_CLIENT_SERVER_PUBLIC_KEY}"
    printf 'Endpoint = %s\n' "${WIREGUARD_CLIENT_ENDPOINT}"
    printf 'AllowedIPs = %s\n' "$(join_by ', ' "${WIREGUARD_CLIENT_ALLOWED_IPS[@]}")"
    printf 'PersistentKeepalive = %s\n' "${WIREGUARD_CLIENT_PERSISTENT_KEEPALIVE}"
  } > "${config_path}"

  chmod 600 "${config_path}"
}

install_wireguard() {
  install_wireguard_packages
  install -d -m 700 "${WIREGUARD_CONFIG_DIR}"

  case "${WIREGUARD_MODE}" in
    server)
      configure_wireguard_ip_forwarding
      write_wireguard_server_config
      ;;
    client)
      write_wireguard_client_config
      ;;
    *)
      die "Unsupported WIREGUARD_MODE=${WIREGUARD_MODE}; use server or client"
      ;;
  esac

  log "WireGuard config written to $(wireguard_config_path)"
  log "WireGuard public key: $(cat "$(wireguard_public_key_path)")"

  if [[ "${WIREGUARD_AUTO_UP}" == "true" ]]; then
    enable_service "wg-quick@${WIREGUARD_INTERFACE}"
  fi
}

install_fail2ban() {
  log "Installing and enabling fail2ban"
  install_packages fail2ban
  enable_service fail2ban
}

main() {
  as_root
  detect_package_manager

  [[ "${RUN_SYSTEM_UPDATE}" == "true" ]] && system_update
  [[ "${INSTALL_BASE_PACKAGES}" == "true" ]] && install_base_packages
  [[ "${CONFIGURE_TIMEZONE}" == "true" ]] && configure_timezone
  [[ "${CREATE_ADMIN_USER}" == "true" ]] && create_admin_user
  [[ "${CONFIGURE_SSH}" == "true" ]] && configure_ssh
  [[ "${CONFIGURE_FIREWALL}" == "true" ]] && configure_firewall
  [[ "${INSTALL_WIREGUARD}" == "true" ]] && install_wireguard
  [[ "${INSTALL_FAIL2BAN}" == "true" ]] && install_fail2ban

  if [[ "${AUTO_REBOOT}" == "true" ]]; then
    log "Rebooting server"
    reboot
  fi

  log "Bootstrap completed"
}

main "$@"
