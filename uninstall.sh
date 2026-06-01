#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
MANIFEST_PORT=9321
CRON_MARKER="# web-finder-serve"
AUTO_PUBLISH_STATE="$HOME/.web-finder-auto-published-ports"

info()  { echo -e "${GREEN}==> ${NC}$1"; }
warn()  { echo -e "${YELLOW}==> ${NC}$1"; }
error() { echo -e "${RED}Error: $1${NC}"; exit 1; }

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    elif command -v doas &>/dev/null; then
        doas "$@"
    else
        return 1
    fi
}

disable_launchagent() {
    local plist="$HOME/Library/LaunchAgents/com.zeul.web-finder-serve.plist"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        launchctl bootout "gui/$(id -u)/com.zeul.web-finder-serve" 2>/dev/null || true
    fi

    if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        info "Removed LaunchAgent autostart"
    fi
}

disable_systemd_user_service() {
    local unit="$HOME/.config/systemd/user/web-finder-serve.service"

    if command -v systemctl &>/dev/null; then
        systemctl --user disable --now web-finder-serve 2>/dev/null || true
    fi

    if [ -f "$unit" ]; then
        rm -f "$unit"
        if command -v systemctl &>/dev/null; then
            systemctl --user daemon-reload 2>/dev/null || true
        fi
        info "Removed systemd user service"
    fi
}

disable_procd_service() {
    local init="/etc/init.d/web-finder"
    [ -f "$init" ] || return 0

    run_root "$init" stop 2>/dev/null || true
    run_root "$init" disable 2>/dev/null || true
    if run_root rm -f "$init" 2>/dev/null; then
        info "Removed OpenWrt procd service"
    else
        warn "Could not remove $init; rerun uninstall as root"
    fi
}

disable_cron_autostart() {
    command -v crontab &>/dev/null || return 0

    local existing next tmp
    existing="$(crontab -l 2>/dev/null || true)"
    if printf '%s\n' "$existing" | grep -Fq "$CRON_MARKER"; then
        next="$(printf '%s\n' "$existing" | grep -Fv "$CRON_MARKER" || true)"
        tmp="$(mktemp)"
        printf '%s\n' "$next" > "$tmp"
        crontab "$tmp"
        rm -f "$tmp"
        info "Removed cron autostart"
    fi
}

stop_pidfile_process() {
    local pidfile="$HOME/.web-finder-serve.pid"
    if [ -f "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile")"
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
        info "Removed pidfile"
    fi
}

disable_tailscale_manifest_serve() {
    command -v tailscale &>/dev/null || return 0

    if [ -f "$AUTO_PUBLISH_STATE" ]; then
        while IFS= read -r port; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                tailscale serve --https="$port" off 2>/dev/null || true
                tailscale serve --http="$port" off 2>/dev/null || true
            fi
        done < "$AUTO_PUBLISH_STATE"
        rm -f "$AUTO_PUBLISH_STATE"
    fi

    tailscale serve --https="$MANIFEST_PORT" off 2>/dev/null || true
    tailscale serve --http="$MANIFEST_PORT" off 2>/dev/null || true
}

remove_cli_symlink() {
    local bin="$1"
    if [ ! -L "$bin" ]; then
        return 0
    fi

    local target
    target="$(readlink "$bin")"
    case "$target" in
        "$HOME/.web-finder"/*)
            if [ -w "$(dirname "$bin")" ]; then
                rm -f "$bin"
            else
                sudo rm -f "$bin"
            fi
            info "Removed CLI from $bin"
            ;;
    esac
}

cleanup_autostart() {
    disable_launchagent
    disable_systemd_user_service
    disable_procd_service
    disable_cron_autostart
    stop_pidfile_process
    disable_tailscale_manifest_serve
}

echo ""
echo "  WebFinder for Tailscale - uninstaller"
echo "  ======================================"
echo ""

WEB_FINDER_BIN=""
if command -v web-finder &>/dev/null; then
    WEB_FINDER_BIN="$(command -v web-finder)"
elif [ -x "$HOME/.web-finder/cli/bin/web-finder" ]; then
    WEB_FINDER_BIN="$HOME/.web-finder/cli/bin/web-finder"
fi

if [ -n "$WEB_FINDER_BIN" ]; then
    if "$WEB_FINDER_BIN" stop >/dev/null 2>&1; then
        info "Stopped WebFinder sharing"
    else
        warn "Could not stop WebFinder sharing cleanly; continuing uninstall"
    fi
fi

cleanup_autostart

if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &>/dev/null; then
    if brew list --cask zeulewan/tap/webfinder &>/dev/null || brew list --cask webfinder &>/dev/null; then
        brew uninstall --cask zeulewan/tap/webfinder
        info "Removed Homebrew cask webfinder"
    fi

    if brew list --formula zeulewan/tap/web-finder &>/dev/null || brew list --formula web-finder &>/dev/null; then
        brew uninstall zeulewan/tap/web-finder
        info "Removed Homebrew formula web-finder"
    fi
fi

# Remove CLI symlink
remove_cli_symlink "/usr/local/bin/web-finder"
remove_cli_symlink "/opt/homebrew/bin/web-finder"

if [ ! -L "/usr/local/bin/web-finder" ] && [ ! -L "/opt/homebrew/bin/web-finder" ]; then
    info "CLI symlink not found, skipping"
fi

# Remove cloned repo
if [ -d "$HOME/.web-finder" ]; then
    rm -rf "$HOME/.web-finder"
    info "Removed ~/.web-finder"
else
    info "$HOME/.web-finder not found, skipping"
fi

# Remove legacy/manual macOS app
if [ -d "/Applications/WebFinder.app" ]; then
    sudo rm -rf "/Applications/WebFinder.app"
    info "Removed /Applications/WebFinder.app"
fi

# Kill running process
if pkill -f "web-finder.*serve" 2>/dev/null; then
    info "Stopped running web-finder manifest server"
fi

if pkill -f WebFinder 2>/dev/null; then
    info "Stopped running WebFinder process"
fi

echo ""
echo -e "${GREEN}Done!${NC} WebFinder has been uninstalled."
echo ""
