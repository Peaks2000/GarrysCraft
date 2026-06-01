#!/usr/bin/env bash
set -euo pipefail

GMOD_DIR="${GMOD_DIR:-$HOME/gmod-ds}"
WORK_DIR="${WORK_DIR:-/tmp/mcgm-luasocket}"
TAG="${TAG:-r1}"
BASE_URL="https://github.com/danielga/gmod_luasocket"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"

usage() {
    cat <<EOF
Usage:
  ./scripts/install-gmod-luasocket.sh

Environment variables:
  GMOD_DIR   Path to your Garry's Mod dedicated server.
             Default: $HOME/gmod-ds
  WORK_DIR   Temporary download folder.
             Default: /tmp/mcgm-luasocket
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

if [[ ! -d "$GMOD_DIR/garrysmod" ]]; then
    cat >&2 <<EOF
Could not find a Garry's Mod server at:
  $GMOD_DIR

Install the dedicated server first:
  ./scripts/install-gmod-server.sh
EOF
    exit 1
fi

if ! command -v wget >/dev/null 2>&1; then
    echo "wget is missing; attempting automatic install..."
    install_package wget || true
fi

if ! command -v wget >/dev/null 2>&1; then
    echo "wget is required for this installer." >&2
    exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "unzip is missing; attempting automatic install..."
    install_package unzip || true
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "unzip is required for this installer." >&2
    exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$GMOD_DIR/garrysmod/lua/bin"

echo "Downloading gmod_luasocket source..."
wget -q -O "$WORK_DIR/gmod_luasocket.zip" "$BASE_URL/archive/refs/tags/$TAG.zip"
unzip -q "$WORK_DIR/gmod_luasocket.zip" -d "$WORK_DIR"

SRC_DIR="$(find "$WORK_DIR" -maxdepth 1 -type d -name 'gmod_luasocket-*' | head -n 1)"
if [[ -z "$SRC_DIR" ]]; then
    echo "Could not find extracted gmod_luasocket source folder." >&2
    exit 1
fi

echo "Installing Lua modules..."
cp -R "$SRC_DIR/includes" "$GMOD_DIR/garrysmod/lua/"

echo "Downloading Linux server binary modules..."
wget -q -O "$GMOD_DIR/garrysmod/lua/bin/gmsv_socket.core_linux.dll" "$BASE_URL/releases/download/$TAG/gmsv_socket.core_linux.dll"
wget -q -O "$GMOD_DIR/garrysmod/lua/bin/gmsv_mime.core_linux.dll" "$BASE_URL/releases/download/$TAG/gmsv_mime.core_linux.dll"

chmod 755 "$GMOD_DIR/garrysmod/lua/bin/gmsv_socket.core_linux.dll"
chmod 755 "$GMOD_DIR/garrysmod/lua/bin/gmsv_mime.core_linux.dll"

cat <<EOF
Installed gmod_luasocket into:
  $GMOD_DIR/garrysmod/lua

Restart your GMod server, then look for:
  [MCGM] listening for Minecraft 1.12.2 backend clients on 127.0.0.1:25566
EOF
