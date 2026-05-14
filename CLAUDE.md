# Web Finder

Network service discovery tool for Tailscale networks. CLI, macOS menu bar app, and iOS app.

## Architecture

- **CLI** (`cli/`): Node.js. Entry point `cli/bin/web-finder`, scanner logic in `cli/scanner.js`
- **macOS app** (`macos/`): Swift, SwiftUI. Built with `swift build` via `macos/build.sh`. Minimum macOS 13.
- **iOS app** (`ios/`): Swift, SwiftUI. Built with `xcodebuild`. Xcode project in `ios/WebFinder.xcodeproj`
- Scanner logic is duplicated across platforms (JS for CLI, Swift for macOS/iOS) - changes often need to go in all three

## Key concepts

- **Default discovery model**: Local clients scan their own machine; remote clients fetch manifests from peers instead of port-scanning them. A peer only shows remote services after Web Finder is installed and `web-finder start` has been run on that peer.
- **Manifest server** (`web-finder serve`, normally launched by `web-finder start`): HTTP server bound to `127.0.0.1:9321` that dynamically scans localhost and serves `/.well-known/web-finder.json`.
- **Tailscale Serve publishing**: `web-finder start` enables Tailscale Serve for the manifest and detected local web UIs. The manifest server re-syncs Serve mappings during manifest refreshes so services started after boot can appear remotely. HTTP backends use `http://127.0.0.1:PORT`; HTTPS/self-signed backends use `https+insecure://127.0.0.1:PORT`.
- **Tailscale serve detection**: The manifest server parses `tailscale serve status` to detect HTTPS proxies and reports `https://` URLs for those ports. Clients use the peer's DNS name (not raw IP) for HTTPS since TLS certs are issued for `.ts.net`.
- **MagicDNS fallback**: If MagicDNS lookup fails, clients may use IP+SNI fallback for manifest fetches and warn that clickable `.ts.net` links need `tailscale set --accept-dns=true`.
- **iOS peer scan behavior**: Normal scans skip API-offline peers. Debug mode includes more diagnostics/noisy peers.
- **Zensical process detection**: On Linux, reads `/proc/PID/cwd` to get project directory names for zensical dev servers instead of generic process names.

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

# iOS App Store archive for local/manual IPA builds, not App Store upload
cd ios && bash build-ios.sh
```

## Deploying

- **CLI/macOS**: `gh release create vX.Y.Z macos/WebFinder.app.zip` - users update via `web-finder update`
- **iOS App Store**: `ios/build-ios.sh` creates an unsigned IPA for local/manual use; it is **not** the App Store upload path.
  1. Bump iOS version/build in `ios/WebFinder.xcodeproj/project.pbxproj` and `ios/WebFinder/Info.plist`. App Store uploads need a new `CFBundleVersion` for every upload; public updates need a new `CFBundleShortVersionString`.
  2. In App Store Connect, create the new app version first: Apps > Web Finder > add iOS version `X.Y.Z`.
  3. Open `ios/WebFinder.xcodeproj` in Xcode.
  4. Select the `WebFinder` scheme and a generic iOS run destination such as `Any iOS Device` / `Generic iOS Device`. Do not archive for a simulator destination.
  5. Run `Product > Archive`.
  6. When Organizer opens, select the archive under `Archives`, click `Distribute App`, choose `App Store Connect`, then upload.
  7. Keep default automatic signing/team `25QMAKVCBN`; enable symbol upload if offered; do not rely on Xcode to silently manage version/build numbers.
  8. Wait for App Store Connect build processing, then go to App Store Connect > Web Finder > version `X.Y.Z`, select the uploaded build, fill release notes/compliance, and submit for review or TestFlight as needed.
  - Terminal archive command that works:
    `xcodebuild archive -project ios/WebFinder.xcodeproj -scheme WebFinder -configuration Release -archivePath ios/build/appstore/WebFinder-X.Y.Z.xcarchive -destination 'generic/platform=iOS' -allowProvisioningUpdates`
  - Terminal upload can be attempted with:
    `xcodebuild -exportArchive -archivePath ios/build/appstore/WebFinder-X.Y.Z.xcarchive -exportOptionsPlist ios/exportOptions.plist -exportPath ios/build/appstore/export -allowProvisioningUpdates`
  - If terminal upload fails with `App Store Connect Credentials Error`, use Xcode Organizer or provide an App Store Connect API issuer ID. Do not document local key filenames/paths in this repo.
- **Manifest/server rollout**: Prefer `web-finder update` on the target machine. It pulls latest, rebuilds/updates the macOS app when applicable, restarts sharing, and reapplies Tailscale Serve. Use `web-finder start` to enable sharing on a fresh install.
- Versions must be bumped in: `cli/package.json`, `macos/Info.plist`, `ios/WebFinder/Info.plist`, `ios/WebFinder.xcodeproj/project.pbxproj`

## Testing changes

- After changing `cli/scanner.js` manifest/serve logic, test the full chain on at least two devices: run `web-finder update` or deploy the branch, then run `web-finder start`, `web-finder status`, and `web-finder --json`.
- Test manifest access through Tailscale Serve with `curl -k https://PEER_DNS:9321/.well-known/web-finder.json`; the server should not need to bind to `0.0.0.0`.
- Test advertised service URLs from another device, especially HTTPS/self-signed local services that require the `https+insecure` Tailscale Serve backend.
- After changing macOS `Scanner.swift`, run `bash build.sh` and relaunch
- After changing iOS `Scanner.swift`, build and install to device via `xcrun devicectl`
- Always compare CLI and app output for parity on Mac, workstation, and iOS when changing discovery behavior.

## App Store Connect Credentials

- Do not commit App Store Connect API key IDs, issuer IDs, private key paths, or `.p8` filenames.
- CLI upload requires an App Store Connect API key plus issuer ID, or a signed-in Xcode account.
- If terminal upload fails with `App Store Connect Credentials Error`, use Xcode Organizer or configure credentials locally outside the repo.
