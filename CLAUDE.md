# Web Finder

Network service discovery tool for Tailscale networks. CLI, macOS menu bar app, and iOS app.

## Architecture

- **CLI** (`cli/`): Node.js. Entry point `cli/bin/web-finder`, scanner logic in `cli/scanner.js`
- **macOS app** (`macos/`): Swift, SwiftUI. Built with `swift build` via `macos/build.sh`. Minimum macOS 13.
- **iOS app** (`ios/`): Swift, SwiftUI. Built with `xcodebuild`. Xcode project in `ios/WebFinder.xcodeproj`
- Scanner logic is duplicated across platforms (JS for CLI, Swift for macOS/iOS) - changes often need to go in all three

## Key concepts

- **Manifest server** (`web-finder serve`): HTTP server on port 9321 that dynamically scans localhost and serves `/.well-known/web-finder.json`. Peers fetch this instead of port scanning.
- **Tailscale serve detection**: The manifest server parses `tailscale serve status` to detect HTTPS proxies and reports `https://` URLs for those ports. Clients use the peer's DNS name (not raw IP) for HTTPS since TLS certs are issued for `.ts.net`.
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

# iOS App Store archive
cd ios && bash build-ios.sh
```

## Deploying

- **CLI/macOS**: `gh release create vX.Y.Z macos/WebFinder.app.zip` - users update via `web-finder --update`
- **iOS**: Archive in Xcode, upload via Organizer > Distribute App > App Store Connect
- **Manifest server on workstation**: `systemctl --user restart web-finder-serve` after updating `~/.web-finder/`
- Versions must be bumped in: `cli/package.json`, `macos/Info.plist`, `ios/WebFinder/Info.plist`

## Testing changes

- After changing `cli/scanner.js` manifest/serve logic, deploy to workstation with `scp` and restart the systemd service, then test with `curl http://PEER_IP:9321/.well-known/web-finder.json`
- After changing macOS `Scanner.swift`, run `bash build.sh` and relaunch
- After changing iOS `Scanner.swift`, build and install to device via `xcrun devicectl`
- Always test the full chain: manifest server output, CLI `--json` output, and actual URL accessibility in browser

## API key for App Store Connect

- Key file: `~/.private_keys/AuthKey_V946Q6Y2C6.p8`
- Key ID: `V946Q6Y2C6`
- CLI upload not currently working (missing issuer ID), use Xcode Organizer instead
