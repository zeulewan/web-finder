#!/bin/bash
set -euo pipefail

REPO="https://github.com/zeulewan/web-finder"
INSTALL_DIR="$HOME/.web-finder"
BIN_DIR="/usr/local/bin"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}==> ${NC}$1"; }
warn()    { echo -e "${YELLOW}==> ${NC}$1"; }
error()   { echo -e "${RED}Error: $1${NC}"; exit 1; }

echo ""
echo "  WebFinder for Tailscale - installer"
echo "  ==================================="
echo ""

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="mac"
elif [[ "$OSTYPE" == "linux-gnu"* ]] || [[ "$OSTYPE" == "linux"* ]]; then
    OS="linux"
else
    error "Unsupported OS: $OSTYPE"
fi

info "Detected: $OS"

if [[ "$OS" == "mac" ]]; then
    command -v brew &>/dev/null || error "Homebrew is required on macOS. Install it from https://brew.sh and re-run."

    info "Installing WebFinder.app and CLI with Homebrew..."
    if brew list --formula zeulewan/tap/web-finder &>/dev/null || brew list --formula web-finder &>/dev/null; then
        brew upgrade zeulewan/tap/web-finder </dev/null
    else
        brew install zeulewan/tap/web-finder </dev/null
    fi

    if brew list --cask zeulewan/tap/webfinder &>/dev/null || brew list --cask webfinder &>/dev/null; then
        brew upgrade --cask zeulewan/tap/webfinder </dev/null
    else
        brew install --cask zeulewan/tap/webfinder </dev/null
    fi

    legacy_bin="/usr/local/bin/web-finder"
    if [ -L "$legacy_bin" ]; then
        legacy_target="$(readlink "$legacy_bin")"
        case "$legacy_target" in
            "$INSTALL_DIR"/*)
                sudo rm -f "$legacy_bin"
                info "Removed legacy CLI symlink at $legacy_bin"
                ;;
        esac
    fi

    if [ -d "$INSTALL_DIR/.git" ]; then
        rm -rf "$INSTALL_DIR"
        info "Removed legacy install at $INSTALL_DIR"
    fi

    echo ""
    echo -e "${GREEN}Done!${NC}"
    echo ""
    echo "  CLI:  web-finder --help"
    echo "  App:  open /Applications/WebFinder.app"
    echo ""
    exit 0
fi

# Check for git
command -v git &>/dev/null || error "git is required. Install it and re-run."

# Check for a supported Node.js without piping remote scripts into a root shell.
command -v node &>/dev/null || error "Node.js 20 or newer is required. Install your distro's Node.js LTS package and re-run."
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if ! [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || [ "$NODE_MAJOR" -lt 20 ]; then
    error "Node.js 20 or newer is required (found $(node --version)). Upgrade Node.js and re-run."
fi

NODE_VER=$(node --version)
info "Node.js $NODE_VER found"

# Clone or update repo
if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing install..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    info "Cloning WebFinder..."
    git clone "$REPO" "$INSTALL_DIR"
fi

# Install CLI
chmod +x "$INSTALL_DIR/cli/bin/web-finder"

if [ -w "$BIN_DIR" ]; then
    ln -sf "$INSTALL_DIR/cli/bin/web-finder" "$BIN_DIR/web-finder"
else
    sudo ln -sf "$INSTALL_DIR/cli/bin/web-finder" "$BIN_DIR/web-finder"
fi

info "CLI installed: web-finder"

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "  CLI:  web-finder --help"
echo ""
