#!/usr/bin/env bash
set -euo pipefail

GMOD_DIR="${GMOD_DIR:-$HOME/gmod-ds}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"

usage() {
    cat <<EOF
Usage:
  ./scripts/install-gmod-server.sh

Environment variables:
  GMOD_DIR   Install path for the Garry's Mod dedicated server.
             Default: $HOME/gmod-ds

Example:
  GMOD_DIR="$HOME/servers/gmod" ./scripts/install-gmod-server.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

run_as_root() {
    if [[ "$(id -u)" == "0" ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n "$@"
    else
        return 1
    fi
}

install_package() {
    local package="$1"

    if [[ "$AUTO_INSTALL_DEPS" != "1" ]]; then
        return 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        run_as_root apt-get update
        DEBIAN_FRONTEND=noninteractive run_as_root apt-get install -y "$package"
        return $?
    fi

    if command -v pacman >/dev/null 2>&1; then
        run_as_root pacman -Sy --noconfirm "$package"
        return $?
    fi

    if command -v dnf >/dev/null 2>&1; then
        run_as_root dnf install -y "$package"
        return $?
    fi

    if command -v yum >/dev/null 2>&1; then
        run_as_root yum install -y "$package"
        return $?
    fi

    return 1
}

if ! command -v steamcmd >/dev/null 2>&1; then
    echo "steamcmd is missing; attempting automatic install..."
    install_package steamcmd || true
fi

if ! command -v steamcmd >/dev/null 2>&1; then
    cat >&2 <<EOF
steamcmd is not installed or is not on PATH.

Automatic install could not complete. Install SteamCMD, then run this script again.

On Arch/Manjaro, it is usually:
  sudo pacman -S steamcmd

If pacman cannot find it, enable the multilib repo in /etc/pacman.conf, then:
  sudo pacman -Syu steamcmd
EOF
    exit 1
fi

mkdir -p "$GMOD_DIR"

echo "Installing/updating Garry's Mod dedicated server into:"
echo "  $GMOD_DIR"

run_steamcmd() {
    steamcmd "$@"
}

if ! run_steamcmd \
    +force_install_dir "$GMOD_DIR" \
    +login anonymous \
    +app_info_update 1 \
    +app_update 4020 validate \
    +quit; then
    cat >&2 <<EOF

SteamCMD failed on the first try. Retrying without validate; this sometimes
gets around SteamCMD's "Missing configuration" metadata/cache error.

EOF

    run_steamcmd \
        +force_install_dir "$GMOD_DIR" \
        +login anonymous \
        +app_info_update 1 \
        +app_update 4020 \
        +quit
fi

cat <<EOF

Done.

Next run:
  GMOD_DIR="$GMOD_DIR" ./scripts/run-gmod-bridge.sh
EOF
