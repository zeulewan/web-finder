# Web Finder Agent Notes

## Project

Network service discovery tool for Tailscale networks. CLI, macOS menu bar app, and iOS app.

## Core Model

- Local clients scan their own machine.
- Remote clients fetch Web Finder manifests from peers instead of port-scanning peers.
- A peer only shows remote services after Web Finder is installed and `web-finder start` has been run on that peer.
- `web-finder start` binds the manifest server to `127.0.0.1:9321` and publishes it through Tailscale Serve.
- The manifest server re-syncs Tailscale Serve mappings during manifest refreshes, so services started after boot can appear remotely.
- HTTPS/self-signed local services must use Tailscale Serve backend URLs like `https+insecure://127.0.0.1:PORT`.

## Release

- Use `scripts/bump-version.sh X.Y.Z [IOS_BUILD]` for version bumps.
- Use `scripts/release.sh X.Y.Z [IOS_BUILD]` for CLI/macOS GitHub releases.
- Use `scripts/archive-ios-appstore.sh X.Y.Z` to create an App Store archive/export attempt. Upload/release may still require signed-in Xcode/App Store Connect credentials.

## Testing

- Check `web-finder status`, `web-finder --json`, and normal `web-finder` output.
- Test from at least two devices when changing manifest/Tailscale Serve behavior.
- Test manifest access with `curl -k https://PEER_DNS:9321/.well-known/web-finder.json`.
- Test advertised service URLs from another device.
- Compare CLI, macOS app, and iOS app output when changing discovery behavior.
