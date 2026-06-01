#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GMOD_DIR="${GMOD_DIR:-$HOME/gmod-ds}"
ADDON_NAME="${ADDON_NAME:-mcgm}"
MAP="${MAP:-gm_flatgrass}"
MAXPLAYERS="${MAXPLAYERS:-16}"
PORT="${PORT:-27015}"
MC_PORT="${MC_PORT:-25565}"
GAMEMODE="${GAMEMODE:-sandbox}"
TICKRATE="${TICKRATE:-33}"
INSTALL_MODE="${INSTALL_MODE:-symlink}"
START_AUTH_PROXY="${START_AUTH_PROXY:-1}"
AUTO_SETUP="${AUTO_SETUP:-1}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"

usage() {
    cat <<EOF
Usage:
  ./scripts/run-gmod-bridge.sh

Environment variables:
  GMOD_DIR       Path to your Garry's Mod dedicated server. Default: $HOME/gmod-ds
  MAP            GMod map. Default: gm_flatgrass
  MAXPLAYERS     GMod player slots. Default: 16
  PORT           GMod server port. Default: 27015
  MC_PORT        Minecraft bridge port from lua/mcgm/config.lua. Default: 25565
  GAMEMODE       GMod gamemode. Default: sandbox
  TICKRATE       srcds tickrate. Default: 33
  INSTALL_MODE   symlink or copy. Default: symlink
                 Existing addon folders are backed up automatically.
  START_AUTH_PROXY
                 1 to start the Minecraft online-mode auth proxy. Default: 1
  AUTO_SETUP     1 to install/update missing server bits automatically. Default: 1
  AUTO_INSTALL_DEPS
                 1 to install missing tools when possible. Default: 1

Examples:
  GMOD_DIR="$HOME/servers/gmod" ./scripts/run-gmod-bridge.sh
  MAP=gm_construct MAXPLAYERS=8 ./scripts/run-gmod-bridge.sh
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

ensure_command() {
    local command_name="$1"
    local package_name="${2:-$1}"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    echo "$command_name is missing; attempting automatic install..."
    install_package "$package_name" || true
    command -v "$command_name" >/dev/null 2>&1
}

if [[ ! -d "$GMOD_DIR" && "$AUTO_SETUP" == "1" ]]; then
    echo "GMod dedicated server missing; installing/updating automatically..."
    GMOD_DIR="$GMOD_DIR" AUTO_INSTALL_DEPS="$AUTO_INSTALL_DEPS" "$ROOT_DIR/scripts/install-gmod-server.sh"
fi

if [[ ! -d "$GMOD_DIR" ]]; then
    cat >&2 <<EOF
Could not find GMOD_DIR:
  $GMOD_DIR

Install a Garry's Mod dedicated server there, or run with:
  GMOD_DIR="/path/to/gmod/server" ./scripts/run-gmod-bridge.sh

Common SteamCMD install command:
  steamcmd +force_install_dir "$HOME/gmod-ds" +login anonymous +app_update 4020 validate +quit
EOF
    exit 1
fi

SRCDS_RUN="$GMOD_DIR/srcds_run"
if [[ ! -x "$SRCDS_RUN" && "$AUTO_SETUP" == "1" ]]; then
    echo "srcds_run missing; installing/updating GMod dedicated server automatically..."
    GMOD_DIR="$GMOD_DIR" AUTO_INSTALL_DEPS="$AUTO_INSTALL_DEPS" "$ROOT_DIR/scripts/install-gmod-server.sh"
fi

if [[ ! -x "$SRCDS_RUN" ]]; then
    cat >&2 <<EOF
Could not execute:
  $SRCDS_RUN

Make sure GMOD_DIR points at a Linux Garry's Mod dedicated server folder.
EOF
    exit 1
fi

ADDONS_DIR="$GMOD_DIR/garrysmod/addons"
TARGET_ADDON="$ADDONS_DIR/$ADDON_NAME"
mkdir -p "$ADDONS_DIR"

if [[ "$INSTALL_MODE" == "copy" ]]; then
    if [[ -e "$TARGET_ADDON" || -L "$TARGET_ADDON" ]]; then
        BACKUP_ADDON="${TARGET_ADDON}.backup.$(date +%Y%m%d-%H%M%S)"
        echo "Existing addon found; moving it to:"
        echo "  $BACKUP_ADDON"
        mv "$TARGET_ADDON" "$BACKUP_ADDON"
    fi
    mkdir -p "$TARGET_ADDON"
    cp -R "$ROOT_DIR/lua" "$ROOT_DIR/README.md" "$TARGET_ADDON/"
else
    if [[ -e "$TARGET_ADDON" || -L "$TARGET_ADDON" ]]; then
        CURRENT_LINK="$(readlink "$TARGET_ADDON" 2>/dev/null || true)"
        if [[ "$CURRENT_LINK" == "$ROOT_DIR" ]]; then
            echo "Addon symlink already points at this repo:"
            echo "  $TARGET_ADDON"
        elif [[ -L "$TARGET_ADDON" ]]; then
            echo "Replacing old addon symlink:"
            echo "  $TARGET_ADDON -> $CURRENT_LINK"
            rm "$TARGET_ADDON"
            ln -s "$ROOT_DIR" "$TARGET_ADDON"
        else
            BACKUP_ADDON="${TARGET_ADDON}.backup.$(date +%Y%m%d-%H%M%S)"
            echo "Existing addon folder found; moving it to:"
            echo "  $BACKUP_ADDON"
            mv "$TARGET_ADDON" "$BACKUP_ADDON"
            ln -s "$ROOT_DIR" "$TARGET_ADDON"
        fi
    else
        ln -s "$ROOT_DIR" "$TARGET_ADDON"
    fi
fi

if [[ "$AUTO_SETUP" == "1" && ! -f "$GMOD_DIR/garrysmod/lua/bin/gmsv_socket.core_linux.dll" ]]; then
    echo "LuaSocket module missing; installing automatically..."
    GMOD_DIR="$GMOD_DIR" AUTO_INSTALL_DEPS="$AUTO_INSTALL_DEPS" "$ROOT_DIR/scripts/install-gmod-luasocket.sh"
fi

cat <<EOF
MC+GM bridge ready.

Addon:
  $TARGET_ADDON

GMod server:
  $GMOD_DIR

Minecraft Java clients:
  Version: 1.12.2
  Address: <your-server-ip>:$MC_PORT

GMod block controls:
  Chat: !block / !breakblock
  Optional binds: bind b mcgm_block_place; bind n mcgm_block_break

Starting srcds...
EOF

AUTH_PROXY_PID=""
if [[ "$START_AUTH_PROXY" == "1" ]]; then
    if ! ensure_command node nodejs; then
        cat >&2 <<EOF
Node.js is required for the Minecraft online-mode auth proxy.
Automatic install could not complete. Install Node.js or run with START_AUTH_PROXY=0 for local backend testing only.
EOF
        exit 1
    fi

    echo "Starting Minecraft online-mode auth proxy..."
    node "$ROOT_DIR/scripts/mc-auth-proxy.js" &
    AUTH_PROXY_PID="$!"
    sleep 0.25
    if ! kill -0 "$AUTH_PROXY_PID" 2>/dev/null; then
        echo "Minecraft online-mode auth proxy failed to start." >&2
        exit 1
    fi

    cleanup_auth_proxy() {
        if [[ -n "$AUTH_PROXY_PID" ]]; then
            kill "$AUTH_PROXY_PID" 2>/dev/null || true
        fi
    }
    trap cleanup_auth_proxy EXIT INT TERM
fi

cd "$GMOD_DIR"
"$SRCDS_RUN" \
    -game garrysmod \
    -console \
    -tickrate "$TICKRATE" \
    -port "$PORT" \
    +map "$MAP" \
    +maxplayers "$MAXPLAYERS" \
    +gamemode "$GAMEMODE"
