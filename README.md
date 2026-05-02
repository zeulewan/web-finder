# Web Finder

**Find web interfaces across your network.**

Stop bookmarking admin pages, docs sites, and test builds. Web Finder discovers web services published by Web Finder clients on your Tailscale devices, plus local services on the machine running it. Fully free and open source.

**[zeulewan.github.io/web-finder](https://zeulewan.github.io/web-finder/)**

## macOS

Menubar app that shows all discovered web services at a glance. Click any service to open in your browser. Auto-refreshes every 60 seconds.

![Web Finder menubar app](docs/mac-dark.png)

## iOS

Discovers services published by Web Finder clients on your tailnet. One-time OAuth setup. Install Web Finder on each Mac/Linux device you want to see, then run `web-finder start` there.

Available on the [App Store](https://apps.apple.com/app/web-finder-for-tailscale/id6759476914) (free).

<p>
  <img src="docs/phone-dark.png" alt="Devices" width="200">
  &nbsp;&nbsp;
  <img src="docs/auth-dark.png" alt="Auth" width="200">
</p>

## Install

```bash
curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/main/install.sh | bash
```

Works on macOS (menubar app + CLI) and Linux (CLI, auto-installs Node.js if missing).

Run this on every Mac/Linux device you want other devices to discover:

```bash
web-finder start
```

That starts the manifest server at boot and publishes detected local web UIs through Tailscale Serve.

To uninstall:

```bash
curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/main/uninstall.sh | bash
```

## CLI

```bash
web-finder                   # Find web services on this machine, router, and tailnet
web-finder start             # Start sharing this machine over Tailscale Serve at boot
web-finder stop              # Stop sharing and disable boot autostart
web-finder status            # Check daemon, Tailscale Serve, MagicDNS, and version
web-finder update            # Pull latest version and restart sharing
web-finder version           # Show version
web-finder --json            # JSON output for apps/scripts
web-finder --debug           # Noisy diagnostics, all open ports, and no-service peers
```

## What it scans

Locally, Web Finder scans listening ports, fetches HTTP `<title>` tags, and identifies running services. Across Tailscale, peers publish a small manifest on port `9321`; clients fetch that manifest instead of port-scanning every peer.

```
80  443  1880  3000  3001  3100  3460  4000  4001  4173
5000  5001  5050  5173  6006  6052  7860  8000-8006
8080-8082  8096  8123  8443  8880  8881  8888  9000
9001  9090  9093  9443  11434  18789  19999  32400
```

Normal output hides protocol/API-only ports and peers with no services. Use `web-finder --debug` when you need the noisy view.
