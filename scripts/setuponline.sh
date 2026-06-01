#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/lua/mcgm/config.lua"

GMOD_DIR="${GMOD_DIR:-$HOME/gmod-ds}"
ADDON_NAME="${ADDON_NAME:-mcgm}"
INSTALL_MODE="${INSTALL_MODE:-symlink}"
INSTALL_LUASOCKET="${INSTALL_LUASOCKET:-auto}"
START_SERVER="${START_SERVER:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-1}"
AUTO_INSTALL_GMOD="${AUTO_INSTALL_GMOD:-1}"

usage() {
    cat <<EOF
Usage:
  ./scripts/setuponline.sh

Environment variables:
  GMOD_DIR            Path to your Garry's Mod dedicated server.
                      Default: $HOME/gmod-ds
  INSTALL_MODE        symlink or copy. Default: symlink
  INSTALL_LUASOCKET   auto, 1, or 0. Default: auto
  START_SERVER        1 to launch srcds after setup, 0 to only install.
                      Default: 0
  AUTO_INSTALL_DEPS   1 to install missing tools when possible. Default: 1
  AUTO_INSTALL_GMOD   1 to install/update GMod DS when missing. Default: 1

Examples:
  ./scripts/setuponline.sh
  ./scripts/run-gmod-bridge.sh
  START_SERVER=1 ./scripts/setuponline.sh
  GMOD_DIR="$HOME/servers/gmod" ./scripts/setuponline.sh
EOF
}

replace_config_bool() {
    local key="$1"
    local value="$2"

    if grep -q "^[[:space:]]*$key[[:space:]]*=" "$CONFIG_FILE"; then
        perl -0pi -e "s/([[:space:]]*$key[[:space:]]*=[[:space:]]*)(true|false)/\${1}$value/m" "$CONFIG_FILE"
    else
        echo "Could not find config key: $key" >&2
        exit 1
    fi
}

replace_config_number() {
    local key="$1"
    local value="$2"

    if grep -q "^[[:space:]]*$key[[:space:]]*=" "$CONFIG_FILE"; then
        perl -0pi -e "s/([[:space:]]*$key[[:space:]]*=[[:space:]]*)[0-9]+/\${1}$value/m" "$CONFIG_FILE"
    else
        echo "Could not find config key: $key" >&2
        exit 1
    fi
}

replace_config_string() {
    local key="$1"
    local value="$2"

    if grep -q "^[[:space:]]*$key[[:space:]]*=" "$CONFIG_FILE"; then
        perl -0pi -e "s#([[:space:]]*$key[[:space:]]*=[[:space:]]*)\"[^\"]*\"#\${1}\"$value\"#m" "$CONFIG_FILE"
    else
        echo "Could not find config key: $key" >&2
        exit 1
    fi
}

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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Could not find config file: $CONFIG_FILE" >&2
    exit 1
fi

if ! ensure_command node nodejs; then
    cat >&2 <<EOF
Node.js is required for the Minecraft online-mode auth proxy.
Automatic install could not complete. Install Node.js, then rerun:
  ./scripts/setuponline.sh
EOF
    exit 1
fi

cat <<EOF
MC+GM one-click setup

This setup uses the supported bridge mode:
  - Public Minecraft online-mode auth proxy: ON
  - Local GMod Lua backend: 127.0.0.1:25566
  - Mojang signed skin/cape lookup: ON

Minecraft clients connect to the auth proxy on port 25565. The proxy performs
Mojang RSA/AES authentication, then forwards verified users to the local backend.
EOF

replace_config_bool "minecraft_online_mode" "false"
replace_config_bool "minecraft_auth_proxy_enabled" "true"
replace_config_bool "enable_minecraft_profile_textures" "true"
replace_config_bool "require_minecraft_profile" "true"
replace_config_bool "force_minecraft_skin_parts" "true"
replace_config_string "bind_host" "127.0.0.1"
replace_config_number "port" "25566"
replace_config_string "auth_proxy_host" "0.0.0.0"
replace_config_number "auth_proxy_port" "25565"

if [[ ! -d "$GMOD_DIR/garrysmod" && "$AUTO_INSTALL_GMOD" == "1" ]]; then
    echo "GMod dedicated server missing; installing/updating automatically..."
    GMOD_DIR="$GMOD_DIR" AUTO_INSTALL_DEPS="$AUTO_INSTALL_DEPS" "$ROOT_DIR/scripts/install-gmod-server.sh"
fi

if [[ ! -d "$GMOD_DIR/garrysmod" ]]; then
    cat >&2 <<EOF

Could not find a Garry's Mod dedicated server at:
  $GMOD_DIR

Install it first:
  ./scripts/install-gmod-server.sh

Or rerun with:
  GMOD_DIR="/path/to/gmod/server" ./scripts/setuponline.sh
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
            echo "Addon symlink already installed:"
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

if [[ "$INSTALL_LUASOCKET" == "1" || "$INSTALL_LUASOCKET" == "auto" ]]; then
    if [[ -f "$GMOD_DIR/garrysmod/lua/bin/gmsv_socket.core_linux.dll" && "$INSTALL_LUASOCKET" == "auto" ]]; then
        echo "LuaSocket module already appears to be installed."
    else
        echo "Installing gmod_luasocket..."
        GMOD_DIR="$GMOD_DIR" "$ROOT_DIR/scripts/install-gmod-luasocket.sh"
    fi
fi

cat <<EOF

Setup complete.

Minecraft client:
  Version: 1.12.2
  Server: <your-gmod-server-ip>:25565

Config fixed:
  bind_host = "127.0.0.1"
  port = 25566
  auth_proxy_port = 25565
  minecraft_auth_proxy_enabled = true
  minecraft_online_mode = false
  enable_minecraft_profile_textures = true
  require_minecraft_profile = true

Run the bridge normally with:
  ./scripts/run-gmod-bridge.sh
EOF

if [[ "$START_SERVER" == "1" ]]; then
    echo
    echo "Starting the GMod bridge server..."
    exec "$ROOT_DIR/scripts/run-gmod-bridge.sh"
fi
