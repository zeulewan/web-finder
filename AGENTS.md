# Web Finder

Network service discovery tool for Tailscale networks. CLI, macOS menu bar app, and iOS app.

## Architecture

- **CLI** (`cli/`): Node.js. Entry point `cli/bin/web-finder`, scanner logic in `cli/scanner.js`
- **macOS app** (`macos/`): Swift, SwiftUI. Built with `swift build` via `macos/build.sh`. Minimum macOS 13.
- **iOS app** (`ios/`): Swift, SwiftUI. Built with `xcodebuild`. Xcode project in `ios/WebFinder.xcodeproj`
- Scanner logic is duplicated across platforms (JS for CLI, Swift for macOS/iOS) - changes often need to go in all three

## Key concepts

- **Default discovery model**: Remote clients fetch manifests from peers instead of port-scanning them. A peer only shows remote services after Web Finder is installed and `web-finder start --auto-publish` or plain `web-finder start` has been run on that peer.
- **Manifest server** (`web-finder serve`, normally launched by `web-finder start`): HTTP server bound to `127.0.0.1:9321` that serves `/.well-known/web-finder.json`.
- **Tailscale Serve publishing**: `web-finder start` exposes the manifest through Tailscale Serve, then advertises only local web UIs already present in `tailscale serve status`. `web-finder start --auto-publish` is the recommended setup because it creates Tailscale Serve mappings for detected local web UIs, but it is explicit and not the default. Auto-publish is a start mode, not a toggle; use `web-finder stop` then plain `web-finder start` to leave it. HTTP backends use `http://127.0.0.1:PORT`; HTTPS/self-signed backends use `https+insecure://127.0.0.1:PORT`.
- **Tailscale serve detection**: The manifest server parses `tailscale serve status` to detect HTTPS proxies and reports `https://` URLs for those ports. Clients use the peer's DNS name (not raw IP) for HTTPS since TLS certs are issued for `.ts.net`.
- **MagicDNS fallback**: If MagicDNS lookup fails, clients may use IP+SNI fallback for manifest fetches and warn that clickable `.ts.net` links need `tailscale set --accept-dns=true`.
- **iOS peer scan behavior**: Normal scans skip API-offline peers. Debug mode includes more diagnostics/noisy peers.
- **Zensical process detection**: On Linux, reads `/proc/PID/cwd` to get project directory names for zensical dev servers instead of generic process names.

## Agent install guidance

- When installing WebFinder for a user, explain the two publisher modes before starting it. Plain `web-finder start` is passive and only advertises services the user already exposed with Tailscale Serve.
- Ask the user before using `web-finder start --auto-publish`. Auto-publish is convenient for individual setups because it creates Tailscale Serve mappings for detected local web UIs, but those services become reachable to devices/users allowed by the tailnet's Tailscale ACLs. Do not enable it silently.

## Building

```bash
# CLI - just run directly
node cli/bin/web-finder

# macOS app
cd macos && bash build.sh
cp -r WebFinder.app ~/Applications/

# iOS app (needs Xcode with iOS SDK installed)
cd ios && xcodebuild -project WebFinder.xcodeproj -scheme WebFinder \
    -destination 'id=DEVICE_ID' -configuration Debug \
    -allowProvisioningUpdates build

# iOS install to device
xcrun devicectl device install app --device DEVICE_ID \
    ~/Library/Developer/Xcode/DerivedData/WebFinder-*/Build/Products/Debug-iphoneos/WebFinder.app

# iOS App Store archive/upload attempt
scripts/archive-ios-appstore.sh X.Y.Z
```

## Deploying

- Full release notes and App Store Connect details live in `docs/release.md`.
- **CLI/macOS**: use `scripts/release.sh X.Y.Z [IOS_BUILD]` for GitHub releases - users update via `web-finder update`
- **iOS App Store**: `ios/build-ios.sh` creates an unsigned IPA for local/manual use; it is **not** the App Store upload path.
  1. Bump iOS version/build in `ios/WebFinder.xcodeproj/project.pbxproj` and `ios/WebFinder/Info.plist`. App Store uploads need a new `CFBundleVersion` for every upload; public updates need a new `CFBundleShortVersionString`.
  2. In App Store Connect, create the new app version first: Apps > Web Finder > add iOS version `X.Y.Z`.
  3. Open `ios/WebFinder.xcodeproj` in Xcode.
  4. Select the `WebFinder` scheme and a generic iOS run destination such as `Any iOS Device` / `Generic iOS Device`. Do not archive for a simulator destination.
  5. Run `Product > Archive`.
  6. When Organizer opens, select the archive under `Archives`, click `Distribute App`, choose `App Store Connect`, then upload.
  7. Keep default automatic signing/team `25QMAKVCBN`; enable symbol upload if offered; do not rely on Xcode to silently manage version/build numbers.
  8. Wait for App Store Connect build processing, then go to App Store Connect > Web Finder > version `X.Y.Z`, select the uploaded build, fill release notes/compliance, and submit for review or TestFlight as needed.
  - Terminal archive/upload helper:
    `scripts/archive-ios-appstore.sh X.Y.Z`
  - Terminal App Store Connect submission helper:
    `scripts/submit-ios-appstore.py X.Y.Z`
  - For CLI upload, set `APP_STORE_CONNECT_KEY_PATH`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`. If terminal upload fails with `App Store Connect Credentials Error`, use Xcode Organizer or configure those credentials locally. Do not document local key filenames/paths in this repo.
- **Manifest/server rollout**: Prefer `web-finder update` on the target machine. It pulls latest, rebuilds/updates the macOS app when applicable, restarts the manifest publisher, and reapplies the manifest Tailscale Serve mapping. Use `web-finder start --auto-publish` for the recommended fresh-install setup, or plain `web-finder start` when you intentionally want the passive publisher that only advertises existing Tailscale Serve mappings.
- Bump versions with `scripts/bump-version.sh X.Y.Z [IOS_BUILD]`. It updates `cli/package.json`, `cli/package-lock.json`, `macos/Info.plist`, `ios/WebFinder/Info.plist`, `ios/WebFinder.xcodeproj/project.pbxproj`, and the website badge.

## Testing changes

- After changing `cli/scanner.js` manifest/serve logic, test the full chain on at least two devices: run `web-finder update` or deploy the branch, then run `web-finder start --auto-publish`, `web-finder status`, and `web-finder --json`. Also test plain `web-finder start` to confirm it remains passive when touching publish behavior.
- Test manifest access through Tailscale Serve with `curl -k https://PEER_DNS:9321/.well-known/web-finder.json`; the server should not need to bind to `0.0.0.0`.
- Test advertised service URLs from another device, especially HTTPS/self-signed local services that require the `https+insecure` Tailscale Serve backend. Plain `web-finder start` should not create new service mappings.
- After changing macOS `Scanner.swift`, run `bash build.sh` and relaunch
- After changing iOS `Scanner.swift`, build and install to device via `xcrun devicectl`
- Always compare CLI and app output for parity on Mac, workstation, and iOS when changing discovery behavior.

## App Store Connect Credentials

- Do not commit App Store Connect API key IDs, issuer IDs, private key paths, or `.p8` filenames.
- CLI upload requires an App Store Connect API key plus issuer ID, or a signed-in Xcode account. `scripts/archive-ios-appstore.sh` reads `APP_STORE_CONNECT_KEY_PATH`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`.
- App Store submission after upload uses the same env vars with `scripts/submit-ios-appstore.py X.Y.Z`. The script creates/updates the App Store version, picks the latest valid App Store-eligible build unless `--build-number` is provided, updates the `en-US` What's New text, adds the version to a review submission, and sends it to review.
- If terminal upload fails with `App Store Connect Credentials Error`, use Xcode Organizer or configure credentials locally outside the repo.
