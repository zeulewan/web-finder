#!/bin/bash
set -e

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
echo "  ======================"
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

# Check for git
command -v git &>/dev/null || error "git is required. Install it and re-run."

# Check for Node.js
if ! command -v node &>/dev/null; then
    if [[ "$OS" == "linux" ]]; then
        warn "Node.js not found. Installing via NodeSource..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
    else
        error "Node.js is required. Install from https://nodejs.org and re-run."
    fi
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

# Mac: download and install the pre-built GUI app
if [[ "$OS" == "mac" ]]; then
    echo ""
    APP_URL="https://github.com/zeulewan/web-finder/releases/latest/download/WebFinder.app.zip"
    APP_ZIP="$INSTALL_DIR/WebFinder.app.zip"

    info "Downloading WebFinder.app..."
    if curl -fsSL -o "$APP_ZIP" "$APP_URL"; then
        # Remove old version if present
        if [ -d "/Applications/WebFinder.app" ]; then
            sudo rm -rf "/Applications/WebFinder.app"
        fi
        sudo rm -rf "/Applications/__MACOSX"
        sudo unzip -oq "$APP_ZIP" -d "/Applications/"
        sudo rm -rf "/Applications/__MACOSX"
        rm -f "$APP_ZIP"
        info "App installed to /Applications/WebFinder.app"
        info "Open it from Finder or run: open /Applications/WebFinder.app"
    else
        warn "Failed to download app - skipping GUI install."
    fi
fi

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "  CLI:  web-finder --help"
if [[ "$OS" == "mac" ]]; then
echo "  App:  open /Applications/WebFinder.app"
fi
echo ""
