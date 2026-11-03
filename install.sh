#!/usr/bin/env bash
# latest-debs one-liner installer.
#
#   curl -fsSL https://latest-debs.github.io/install.sh | sh
#
# The ONLY privileged actions this script performs are:
#   1. installing the repository's GPG key into /etc/apt/keyrings/
#   2. writing one apt sources file into /etc/apt/sources.list.d/
#   3. writing one apt preferences file into /etc/apt/preferences.d/
#
# These are plain, human-readable config files — review them (and this script)
# before running. Nothing else is executed, downloaded, or modified.
#
# Compatibility:
# * Debian and Ubuntu
# * Downstream releases from Debian and Ubuntu:
#   - LinuxMint (Ubuntu)
#   - LMDE (Debian)
#   - Devuan (Debian)
#   - Distros downstream from Devuan which is downstream from Debian
#
# Usage:
#   install.sh              add the repo for the detected Debian/Ubuntu suite
#   install.sh --uninstall  remove the keyring and sources file
#   install.sh --status     show what is installed

set -euo pipefail

REPO_URL="https://latest-debs.ranjithraj.workers.dev/"
KEY_URL="https://latest-debs.github.io/apt-repo/latest-debs.asc"
KEYRING="/etc/apt/keyrings/latest-debs.gpg"
SOURCES="/etc/apt/sources.list.d/latest-debs.sources"
SOURCES_LIST="/etc/apt/sources.list.d/latest-debs.list"
PREFS="/etc/apt/preferences.d/latest-debs.pref"
SUPPORTED="bookworm trixie forky sid jammy noble questing resolute"

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"
run() { if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi; }

case "${1:-}" in
  --uninstall)
    run rm -f "$KEYRING" "$SOURCES" "$SOURCES_LIST" "$PREFS"
    run apt-get update -qq || true
    msg "latest-debs repository removed."
    exit 0
    ;;
  --status)
    if [ -f "$SOURCES" ]; then
      echo "--- $SOURCES ---"; cat "$SOURCES"
      echo "--- $KEYRING ---"
      command -v gpg >/dev/null && gpg --show-keys "$KEYRING" 2>/dev/null | sed -n '2p'
      if [ -f "$PREFS" ]; then
        echo "--- $PREFS ---"; cat "$PREFS"
      fi
    elif [ -f "$SOURCES_LIST" ]; then
      echo "--- $SOURCES_LIST ---"; cat "$SOURCES_LIST"
      echo "--- $KEYRING ---"
      command -v gpg >/dev/null && gpg --show-keys "$KEYRING" 2>/dev/null | sed -n '2p'
      if [ -f "$PREFS" ]; then
        echo "--- $PREFS ---"; cat "$PREFS"
      fi
    else
      echo "latest-debs repository is not installed"
    fi
    exit 0
    ;;
  "") ;;
  *) die "unknown option: $1 (try --uninstall or --status)" ;;
esac

# --- Distro / suite detection -------------------------------------------------
[ -r /etc/os-release ] || die "/etc/os-release not found - not a Debian-family system?"
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *)
  case "${ID_LIKE:-}" in *debian*|*ubuntu*) ;; *) die "unsupported distro '${ID:-?}' - Debian and Ubuntu only";; esac ;;
esac

# Map distro codenames downstream from Debian or Ubuntu
if [ -n "$UBUNTU_CODENAME" ]; then
  # Get name from LinuxMint (based on Ubuntu)
  CODENAME="$UBUNTU_CODENAME"
elif [ -n "$DEBIAN_CODENAME" ]; then
  # Get name from LinuxMint LMDE (based on Debian)
  CODENAME="$DEBIAN_CODENAME"
else
  # Codename from Debian or Ubuntu, etc.
  CODENAME="${VERSION_CODENAME:-}"
  # Map Devuan codename to Debian codename
  case "$CODENAME" in
    freia) CODENAME="forky" ;;
    excalibur) CODENAME="trixie" ;;
    daedalus) CODENAME="bookworm" ;;
  esac
fi

[ -n "$CODENAME" ] || CODENAME="$(lsb_release -cs 2>/dev/null || true)"
[ -n "$CODENAME" ] || die "could not detect the release codename"

suite_ok=""
for s in $SUPPORTED; do [ "$s" = "$CODENAME" ] && suite_ok=1; done
if [ -z "$suite_ok" ]; then
  die "suite '$CODENAME' is not served yet. Supported: $SUPPORTED"
fi

msg "Using CODENAME=$CODENAME"

# --- Prerequisites ------------------------------------------------------------
if ! command -v curl >/dev/null || ! command -v gpg >/dev/null; then
  msg "installing prerequisites (curl, gnupg)"
  run apt-get update -qq
  run apt-get install -y -qq curl gnupg
fi

# --- Key + sources (the only privileged writes) --------------------------------
msg "installing repository key"
run install -d -m 0755 /etc/apt/keyrings
tmpkey="$(mktemp)"
curl -fsSL "$KEY_URL" -o "$tmpkey" || { rm -f "$tmpkey"; die "could not download $KEY_URL"; }
run gpg --dearmor --yes -o "$KEYRING" "$tmpkey"
rm -f "$tmpkey"
run chmod 0644 "$KEYRING"

msg "writing $SOURCES ($CODENAME)"
run tee "$SOURCES" > /dev/null <<EOF
Types: deb
URIs: $REPO_URL
Suites: $CODENAME
Components: main
Signed-By: $KEYRING
Enabled: yes
EOF

msg "writing $PREFS ($CODENAME)"
run tee "$PREFS" > /dev/null <<EOF
Package: *
Pin: origin latest-debs.ranjithraj.workers.dev
Pin-Priority: 940
EOF

msg "updating apt indexes"
run apt-get update -qq

cat <<EOF

Done. 

Check "eza" package priorities to ensure latest-debs packages would be installed:

  apt-cache policy eza

Check "eza" package install dependencies without actually installing:

  sudo apt install --dry-run eza

Full catalog: https://latest-debs.github.io/
EOF
