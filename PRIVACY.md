# Privacy Policy

**WebFinder for Tailscale** does not collect, store, or transmit any personal data.

## What the app does

- Connects to the Tailscale API using OAuth credentials you provide, or to a WebFinder publisher URL you configure, to discover devices on your tailnet
- Fetches WebFinder manifests from devices where WebFinder is installed and running
- Scans local services only on the device running WebFinder
- Opens URLs in your default browser when you tap a service

## Data storage

- Your Tailscale OAuth Client Secret is stored locally in the iOS Keychain; the Client ID and optional publisher URL are stored in app preferences
- No data is sent to any third-party server, analytics service, or tracking platform
- No usage data, crash reports, or telemetry of any kind is collected

## Network access

- The app connects to `api.tailscale.com` to authenticate with Tailscale and retrieve your device list
- When you configure publisher mode, the app instead fetches a global manifest directly from that tailnet device
- The app connects directly to WebFinder manifest endpoints on your Tailscale devices, normally on port `9321`
- The app connects to service URLs on your tailnet or local network when you open them
- The iOS app does not port-scan Tailscale peers; peer services are published by WebFinder running on those peers

## Third-party services

When OAuth mode is used, the app uses the Tailscale API solely to discover your devices. Tailscale's own privacy policy applies to their service: https://tailscale.com/privacy-policy

## Contact

If you have questions about this privacy policy, open an issue at https://github.com/zeulewan/web-finder/issues

*Last updated: August 28, 2026*
