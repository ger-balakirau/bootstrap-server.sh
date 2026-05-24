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
INSTALL_FAIL2BAN=true
AUTO_REBOOT=false

TIMEZONE="UTC"

ADMIN_USER="deploy"
ADMIN_SSH_PUBLIC_KEY=""
ADMIN_PASSWORDLESS_SUDO=true

SSH_PORT="22"
SSH_DISABLE_ROOT_LOGIN=true
SSH_DISABLE_PASSWORD_AUTH=false

# Firewall backend: auto, ufw, firewalld, nftables
FIREWALL_BACKEND="auto"
FIREWALL_ALLOW_SSH=true
FIREWALL_ALLOWED_TCP_PORTS=("80" "443")
FIREWALL_ALLOWED_UDP_PORTS=()

BASE_PACKAGES_DEBIAN=(
  ca-certificates
  curl
  gnupg
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

ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    printf 'ssh'
  else
    printf 'sshd'
  fi
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

  for port in "${FIREWALL_ALLOWED_TCP_PORTS[@]}"; do
    ufw allow "${port}/tcp"
  done

  for port in "${FIREWALL_ALLOWED_UDP_PORTS[@]}"; do
    ufw allow "${port}/udp"
  done

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

  for port in "${FIREWALL_ALLOWED_TCP_PORTS[@]}"; do
    firewall-cmd --permanent --add-port="${port}/tcp"
  done

  for port in "${FIREWALL_ALLOWED_UDP_PORTS[@]}"; do
    firewall-cmd --permanent --add-port="${port}/udp"
  done

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
  [[ "${INSTALL_FAIL2BAN}" == "true" ]] && install_fail2ban

  if [[ "${AUTO_REBOOT}" == "true" ]]; then
    log "Rebooting server"
    reboot
  fi

  log "Bootstrap completed"
}

main "$@"
