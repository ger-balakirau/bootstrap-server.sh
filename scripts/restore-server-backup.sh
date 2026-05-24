#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./restore-server-backup.sh <ssh-host> <backup-archive.tar.gz>

Example:
  ./restore-server-backup.sh dev ./dev/dev-backup-20260524-155316.tar.gz

The script copies the archive to the remote host, extracts it under a temporary
directory, backs up current target paths, restores saved files, and restarts
affected services when they exist.
USAGE
}

if [[ "$#" -ne 2 ]]; then
  usage >&2
  exit 2
fi

HOST="$1"
ARCHIVE="$2"

if [[ ! -f "${ARCHIVE}" ]]; then
  printf 'ERROR: archive not found: %s\n' "${ARCHIVE}" >&2
  exit 1
fi

ARCHIVE_BASENAME="$(basename -- "${ARCHIVE}")"
REMOTE_ARCHIVE="/tmp/${ARCHIVE_BASENAME}"
REMOTE_WORKDIR="/tmp/server-backup-restore-${USER}-$(date +%Y%m%d%H%M%S)"

printf 'Copying %s to %s:%s\n' "${ARCHIVE}" "${HOST}" "${REMOTE_ARCHIVE}"
scp -- "${ARCHIVE}" "${HOST}:${REMOTE_ARCHIVE}"

# shellcheck disable=SC2029
ssh "${HOST}" "sudo -i env REMOTE_ARCHIVE='${REMOTE_ARCHIVE}' REMOTE_WORKDIR='${REMOTE_WORKDIR}' bash -s" <<'REMOTE'
set -euo pipefail

archive="${REMOTE_ARCHIVE:?}"
workdir="${REMOTE_WORKDIR:?}"
timestamp="$(date +%Y%m%d%H%M%S)"

mkdir -p "${workdir}"
tar -xzf "${archive}" -C "${workdir}"

payload="${workdir}/payload"
if [[ ! -d "${payload}" ]]; then
  echo "ERROR: payload directory not found in archive" >&2
  exit 1
fi

restore_path() {
  local relative_path="$1"
  local source_path="${payload}/${relative_path}"
  local target_path="/${relative_path}"
  local parent_path

  if [[ ! -e "${source_path}" ]]; then
    return 0
  fi

  parent_path="$(dirname -- "${target_path}")"
  mkdir -p "${parent_path}"

  if [[ -e "${target_path}" ]]; then
    mv "${target_path}" "${target_path}.pre-restore-${timestamp}"
  fi

  cp -a "${source_path}" "${target_path}"
}

restore_path "etc/wireguard"
restore_path "etc/ssh/sshd_config"
restore_path "etc/ssh/sshd_config.d"
restore_path "etc/ufw"
restore_path "etc/fail2ban"
restore_path "root/bootstrap-server.sh"

if [[ -d /etc/wireguard ]]; then
  chmod 700 /etc/wireguard
  find /etc/wireguard -type f -exec chmod 600 {} +
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  systemctl restart wg-quick@wg0 2>/dev/null || true
fi

rm -f "${archive}"
echo "Restore completed from ${archive}"
REMOTE
