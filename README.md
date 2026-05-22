# WebFinder for Tailscale

**Find web interfaces across your tailnet.**

Install WebFinder on each Mac or Linux device whose web UIs you want to see, then run `web-finder start --auto-publish` for the recommended setup. Auto-publish lets WebFinder configure Tailscale Serve for detected local web UIs. It is not the default: plain `web-finder start` stays passive and only advertises web UIs you already exposed with Tailscale Serve.

Stop bookmarking admin pages, docs sites, homelab dashboards, and test builds. Fully free and open source.

**[zeulewan.github.io/web-finder](https://zeulewan.github.io/web-finder/)**

Setup details: [zeulewan.github.io/web-finder/docs.html](https://zeulewan.github.io/web-finder/docs.html)

## macOS

Menubar app for Tailscale users. It shows discovered web services at a glance, opens them in your browser, and gives you one-click refresh when services change.

![WebFinder menubar app](docs/mac-dark.png)

## iOS

Discovers services published by WebFinder clients on your tailnet. One-time Tailscale OAuth setup. Install WebFinder on each Mac/Linux device you want to see, then run `web-finder start --auto-publish` there for the recommended setup.

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
curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/refs/heads/main/install.sh | bash
```

Then start the manifest publisher on each Mac/Linux device you want remote clients to discover. Recommended setup:

```bash
web-finder start --auto-publish
```

That starts the local manifest server, enables autostart where supported, and lets WebFinder publish detected local web UIs through Tailscale Serve. Remote WebFinder clients fetch that manifest instead of port-scanning your peers.

On Linux, auto-publish may prompt to set the current Unix user as the local Tailscale operator. This lets WebFinder manage Tailscale Serve mappings for detected web UIs without running as root. `sudo` may ask for your password the first time.

Passive/default mode is still available if you only want to advertise web UIs you already exposed yourself with Tailscale Serve:

```bash
web-finder start
```

Release and App Store submission notes for maintainers live in [docs/release.md](docs/release.md).

To uninstall from macOS or Linux:

```bash
curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/refs/heads/main/uninstall.sh | bash
```

## CLI

```bash
web-finder                   # Find local services and Tailscale-published peer services
web-finder start --auto-publish  # Recommended: publish detected local web UIs with Tailscale Serve
web-finder start             # Passive default: only advertise existing Tailscale Serve mappings
web-finder stop              # Stop sharing and disable autostart
web-finder status            # Check daemon, Tailscale Serve, MagicDNS, and version
web-finder update            # Update WebFinder and restart sharing
web-finder version           # Show version
web-finder --json            # JSON output for apps/scripts
web-finder --debug           # Noisy diagnostics, all open ports, and no-service peers
```

## How discovery works

WebFinder for Tailscale is intentionally Tailscale-first:

- For remote discovery, each Mac/Linux publisher reads its own Tailscale Serve mappings and fetches titles locally.
- `web-finder start --auto-publish` is the recommended setup: it publishes a small manifest at `/.well-known/web-finder.json` on port `9321`, enables autostart where supported, and asks Tailscale Serve to expose detected local web UIs.
- Auto-publish is not the default. Plain `web-finder start` stays passive and only advertises local web UIs already exposed with Tailscale Serve.
- On Linux, auto-publish may prompt to set the current Unix user as the local Tailscale operator so WebFinder can manage Tailscale Serve mappings without running as root.
- `web-finder stop` removes the Tailscale Serve mappings WebFinder created in auto-publish mode.
- Other clients fetch peer manifests instead of scanning peer ports.
- Normal output hides protocol/API-only ports and peers with no services. Use `web-finder --debug` for the noisy view.

Remote services only appear after WebFinder is installed and started on the peer.

`web-finder start` and `web-finder start --auto-publish` both install an autostart entry where supported: a LaunchAgent on macOS, a systemd user service on most Linux systems, or a cron fallback on Synology/non-systemd systems.

## Development

```bash
npm install --prefix cli
npm run check
```

`npm run check` runs ESLint for the CLI, SwiftLint for the macOS/iOS sources, Node syntax checks, and shell syntax checks.
