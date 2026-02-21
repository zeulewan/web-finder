# Web Finder

Find web interfaces running across your local machine and Tailscale network.

**[zeulewan.github.io/web-finder](https://zeulewan.github.io/web-finder/)**

![Web Finder menubar app](docs/app-screenshot.png)

## Install

```bash
curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/main/install.sh | bash
```

- **macOS**: Downloads the menubar app + installs the CLI
- **Ubuntu/Linux**: Installs the CLI (auto-installs Node.js if missing)

## Menubar App (macOS)

A menubar icon that shows all discovered web services at a glance. Click any service to open in your browser.

- Pre-scans on launch for instant results
- Auto-refreshes every 60 seconds
- Settings toggle to show all open ports (including non-web like AirPlay, SSH)
- Right-click to copy URLs

## CLI

```bash
web-finder                   # Full scan, web interfaces only
web-finder --all             # Full scan, all open ports
web-finder --local           # Local machine only
web-finder --tailscale       # Tailscale peers only
web-finder --json            # JSON output (for scripts/agents)
web-finder --local --json    # Local only, JSON
```

## How it works

- **Local**: TCP-scans common ports, fetches HTTP `<title>` tags, identifies processes via `pgrep`
- **Tailscale**: Queries `tailscale status --json` for peers, scans each online peer in parallel
- **Filtering**: By default only shows ports serving actual web pages. Use `--all` or the settings toggle to include non-web services

## Ports scanned

```
80, 443, 3000, 3001, 4000, 4001, 5000, 5001, 6006, 7860,
8000-8005, 8080-8082, 8443, 8888, 9000, 9001, 9090, 9443
```
