WebFinder 1.4.0 makes discovery safer and much more reliable on slow or newly connected tailnet paths.

- iPhone refreshes reuse OAuth tokens, retry cold connections, preserve cached services, and refresh when returning to the foreground.
- OAuth secrets migrate into the iOS Keychain.
- A WebFinder publisher URL offers credential-free iPhone discovery; print it with `web-finder qr`.
- Auto-publish now reconciles only exact WebFinder-owned Tailscale Serve routes and preserves conflicts or user changes.
- Status has structured JSON, route drift details, daemon health, and service configuration diagnostics.
- Linux and macOS listener discovery is dynamic while filtering APIs, browser debugging sockets, and system protocols.
- macOS launches from a cache and avoids duplicate startup scans.
- Install, uninstall, manifest validation, TLS handling, redirects, dependencies, and release automation are hardened.

The macOS app archive is attached only when it is Developer ID signed and notarized. The CLI remains available from the source archive and Homebrew formula.
