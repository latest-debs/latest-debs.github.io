#!/usr/bin/env bash
# latest-debs one-liner installer.
#
#   curl -fsSL https://latest-debs.github.io/install.sh | sh
#
# The ONLY privileged actions this script performs are:
#   1. installing the repository's GPG key into /etc/apt/keyrings/
#   2. writing one apt sources file into /etc/apt/sources.list.d/
# Both are plain, human-readable config — review them (and this script)
# before running. Nothing else is executed, downloaded, or modified.
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
SUPPORTED="bookworm trixie forky sid jammy noble questing resolute"

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"
run() { if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi; }

case "${1:-}" in
  --uninstall)
    run rm -f "$KEYRING" "$SOURCES"
    run apt-get update -qq || true
    msg "latest-debs repository removed."
    exit 0
    ;;
  --status)
    if [ -f "$SOURCES" ]; then
      echo "--- $SOURCES ---"; cat "$SOURCES"
      command -v gpg >/dev/null && gpg --show-keys "$KEYRING" 2>/dev/null | sed -n '2p'
    else
      echo "not installed"
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

CODENAME="${VERSION_CODENAME:-}"
[ -n "$CODENAME" ] || CODENAME="$(lsb_release -cs 2>/dev/null || true)"
[ -n "$CODENAME" ] || die "could not detect the release codename"

suite_ok=""
for s in $SUPPORTED; do [ "$s" = "$CODENAME" ] && suite_ok=1; done
if [ -z "$suite_ok" ]; then
  die "suite '$CODENAME' is not served yet. Supported: $SUPPORTED"
fi

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
EOF

msg "updating apt indexes"
run apt-get update -qq

cat <<EOF

Done. Try it:

  sudo apt install uv eza lazygit

Full catalog: https://latest-debs.github.io/
EOF
