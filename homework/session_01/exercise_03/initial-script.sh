#!/usr/bin/env bash
#
# QuickBite initial environment setup.
#
# Target: Ubuntu 24.04 container (run as root inside the container).
# The container is disposable; no host state is modified by this script.
#
set -Eeuo pipefail

trap 'rc=$?; printf "[FAIL] command failed at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

readonly PACKAGES=(openjdk-17-jdk git curl)
readonly QB_USER="quickbite"
readonly QB_GROUP="quickbite"
readonly QB_SHELL="/bin/false"
readonly QB_HOME="/nonexistent"

log()  { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
err()  { printf '[FAIL] %s\n' "$*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "this script must run as root inside the Ubuntu container"
    exit 1
  fi
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

java17_available() {
  local candidate
  for candidate in \
    /usr/lib/jvm/java-17-openjdk-amd64/bin/java \
    /usr/lib/jvm/java-17-openjdk-amd64/bin/javac
  do
    [[ -x "$candidate" ]] || continue
    if "$candidate" -version 2>&1 | grep -q 'version "17\|^javac 17'; then
      return 0
    fi
  done
  return 1
}

update_and_install() {
  log "Updating APT metadata"
  apt-get update

  log "Upgrading installed packages"
  apt-get upgrade -y

  log "Installing required packages: ${PACKAGES[*]}"
  apt-get install -y "${PACKAGES[@]}"
}

ensure_group() {
  if getent group "$QB_GROUP" >/dev/null 2>&1; then
    ok "group '$QB_GROUP' already exists"
  else
    log "Creating system group '$QB_GROUP'"
    groupadd --system "$QB_GROUP"
    ok "group '$QB_GROUP' created"
  fi
}

ensure_user() {
  local desired_gid current_gid current_shell

  desired_gid="$(getent group "$QB_GROUP" | cut -d: -f3)"

  if getent passwd "$QB_USER" >/dev/null 2>&1; then
    ok "user '$QB_USER' already exists"
    current_gid="$(getent passwd "$QB_USER" | cut -d: -f4)"
    current_shell="$(getent passwd "$QB_USER" | cut -d: -f7)"

    if [[ "$current_gid" != "$desired_gid" || "$current_shell" != "$QB_SHELL" ]]; then
      log "Correcting primary group/shell for existing user '$QB_USER'"
      usermod --gid "$QB_GROUP" --shell "$QB_SHELL" "$QB_USER"
      ok "user '$QB_USER' updated (group '$QB_GROUP', shell '$QB_SHELL')"
    fi
  else
    log "Creating system user '$QB_USER' without a home directory"
    useradd \
      --system \
      --gid "$QB_GROUP" \
      --no-create-home \
      --home-dir "$QB_HOME" \
      --shell "$QB_SHELL" \
      --comment "QuickBite service account" \
      "$QB_USER"
    ok "user '$QB_USER' created"
  fi
}

verify_setup() {
  local uid gid passwd_gid passwd_shell passwd_home

  log "Verifying installed packages"
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    package_installed "$pkg" || { err "package '$pkg' is not installed"; exit 1; }
  done
  ok "required packages installed"

  java17_available || { err "Java 17 is not available"; exit 1; }
  ok "Java 17 is available"
  command -v git >/dev/null || { err "git is not available"; exit 1; }
  command -v curl >/dev/null || { err "curl is not available"; exit 1; }
  ok "git and curl are available"

  getent group "$QB_GROUP" >/dev/null || { err "group '$QB_GROUP' missing"; exit 1; }
  getent passwd "$QB_USER" >/dev/null || { err "user '$QB_USER' missing"; exit 1; }

  uid="$(id -u "$QB_USER")"
  gid="$(getent group "$QB_GROUP" | cut -d: -f3)"
  passwd_gid="$(getent passwd "$QB_USER" | cut -d: -f4)"
  passwd_shell="$(getent passwd "$QB_USER" | cut -d: -f7)"
  passwd_home="$(getent passwd "$QB_USER" | cut -d: -f6)"

  [[ "$passwd_gid" == "$gid" ]] || { err "primary GID mismatch ($passwd_gid != $gid)"; exit 1; }
  [[ "$passwd_shell" == "$QB_SHELL" ]] || { err "login shell is '$passwd_shell', expected '$QB_SHELL'"; exit 1; }
  [[ "$passwd_home" == "$QB_HOME" ]] || { err "home field is '$passwd_home', expected '$QB_HOME'"; exit 1; }
  [[ ! -e "/home/$QB_USER" ]] || { err "/home/$QB_USER was created"; exit 1; }

  ok "group '$QB_GROUP' exists (gid $gid)"
  ok "user '$QB_USER' exists (uid $uid, gid $passwd_gid)"
  ok "login shell is $passwd_shell"
  ok "no personal home directory was created"

  log "Final account state"
  id "$QB_USER"
  getent group "$QB_GROUP"
  getent passwd "$QB_USER"
}

main() {
  require_root
  update_and_install
  ensure_group
  ensure_user
  verify_setup
  ok "QuickBite setup completed successfully"
}

main "$@"
