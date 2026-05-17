#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}==> ${NC}$1"; }
error() { echo -e "${RED}Error: $1${NC}"; exit 1; }

echo ""
echo "  WebFinder for Tailscale - uninstaller"
echo "  ========================"
echo ""

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
if [ -L "/usr/local/bin/web-finder" ]; then
    if [ -w "/usr/local/bin" ]; then
        rm -f "/usr/local/bin/web-finder"
    else
        sudo rm -f "/usr/local/bin/web-finder"
    fi
    info "Removed CLI from /usr/local/bin/web-finder"
else
    info "CLI symlink not found, skipping"
fi

# Remove cloned repo
if [ -d "$HOME/.web-finder" ]; then
    rm -rf "$HOME/.web-finder"
    info "Removed ~/.web-finder"
else
    info "~/.web-finder not found, skipping"
fi

# Remove legacy/manual macOS app
if [ -d "/Applications/WebFinder.app" ]; then
    sudo rm -rf "/Applications/WebFinder.app"
    info "Removed /Applications/WebFinder.app"
fi

# Kill running process
pkill -f WebFinder 2>/dev/null && info "Stopped running WebFinder process" || true

echo ""
echo -e "${GREEN}Done!${NC} WebFinder has been uninstalled."
echo ""
