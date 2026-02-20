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
echo "  Web Finder - installer"
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
    info "Cloning Web Finder..."
    git clone "$REPO" "$INSTALL_DIR"
fi

# Install CLI
chmod +x "$INSTALL_DIR/bin/web-finder"

if [ -w "$BIN_DIR" ]; then
    ln -sf "$INSTALL_DIR/bin/web-finder" "$BIN_DIR/web-finder"
else
    sudo ln -sf "$INSTALL_DIR/bin/web-finder" "$BIN_DIR/web-finder"
fi

info "CLI installed: web-finder"

# Mac: build and install the GUI app
if [[ "$OS" == "mac" ]]; then
    echo ""
    if command -v swift &>/dev/null; then
        info "Building Web Finder.app (this takes ~10s)..."
        cd "$INSTALL_DIR"
        bash build.sh > /dev/null 2>&1
        # Install to ~/Applications, creating it if needed
        mkdir -p "$HOME/Applications"
        cp -r WebFinder.app "$HOME/Applications/"
        info "App installed to ~/Applications/WebFinder.app"
        info "Open it from Finder or run: open ~/Applications/WebFinder.app"
    else
        warn "Swift not found - skipping GUI app."
        warn "Install Xcode from the App Store to get the menubar app."
    fi
fi

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "  CLI:  web-finder --help"
if [[ "$OS" == "mac" ]]; then
echo "  App:  open ~/Applications/WebFinder.app"
fi
echo ""
