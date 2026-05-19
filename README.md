# WebFinder for Tailscale

**Find web interfaces across your tailnet.**

Install WebFinder on each Mac or Linux device whose web UIs you want to see, then run `web-finder start` once to launch the background manifest daemon and enable autostart. WebFinder for Tailscale discovers those published services across your tailnet, plus local services on the machine running it.

Stop bookmarking admin pages, docs sites, homelab dashboards, and test builds. Fully free and open source.

**[zeulewan.github.io/web-finder](https://zeulewan.github.io/web-finder/)**

## macOS

Menubar app for Tailscale users. It shows discovered web services at a glance, opens them in your browser, and gives you one-click refresh when services change.

![WebFinder menubar app](docs/mac-dark.png)

## iOS

Discovers services published by WebFinder clients on your tailnet. One-time Tailscale OAuth setup. Install WebFinder on each Mac/Linux device you want to see, then run `web-finder start` there.

Available on the [App Store](https://apps.apple.com/app/web-finder-for-tailscale/id6759476914) (free).

<p>
  <img src="docs/phone-dark.png" alt="Devices" width="200">
  &nbsp;&nbsp;
  <img src="docs/auth-dark.png" alt="Auth" width="200">
</p>

## Install

On macOS, install the signed and notarized menu bar app plus CLI with Homebrew:

```bash
brew install --cask zeulewan/tap/webfinder
```

On Linux, install the CLI publisher:

```bash
curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/main/install.sh | bash
```

Then start sharing each Mac/Linux device you want remote clients to discover:

```bash
web-finder start
```

That starts the local manifest server, enables autostart where supported, and publishes detected local web UIs through Tailscale Serve. Remote WebFinder clients fetch that manifest instead of port-scanning your peers.

Release and App Store submission notes for maintainers live in [docs/release.md](docs/release.md).

To uninstall from macOS or Linux:

```bash
curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/main/uninstall.sh | bash
```

## CLI

```bash
web-finder                   # Find local services and Tailscale-published peer services
web-finder start             # Start the background manifest daemon and enable autostart
web-finder stop              # Stop sharing and disable autostart
web-finder status            # Check daemon, Tailscale Serve, MagicDNS, and version
web-finder update            # Update WebFinder and restart sharing
web-finder version           # Show version
web-finder --json            # JSON output for apps/scripts
web-finder --debug           # Noisy diagnostics, all open ports, and no-service peers
```

## How discovery works

WebFinder for Tailscale is intentionally Tailscale-first:

- Each Mac/Linux device scans only itself.
- `web-finder start` publishes a small manifest at `/.well-known/web-finder.json` on port `9321` and enables autostart where supported.
- Tailscale Serve exposes that manifest and the discovered service URLs to your tailnet.
- Other clients fetch peer manifests instead of scanning peer ports.
- Normal output hides protocol/API-only ports and peers with no services. Use `web-finder --debug` for the noisy view.

Remote services only appear after WebFinder is installed and started on the peer.

`web-finder start` installs an autostart entry where supported: a LaunchAgent on macOS, a systemd user service on most Linux systems, or a cron fallback on Synology/non-systemd systems.

## Development

```bash
npm install --prefix cli
npm run check
```

`npm run check` runs ESLint for the CLI, SwiftLint for the macOS/iOS sources, Node syntax checks, and shell syntax checks.
