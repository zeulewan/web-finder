# Privacy Policy

**Web Finder** does not collect, store, or transmit any personal data.

## What the app does

- Connects to the Tailscale API using OAuth credentials you provide to discover devices on your tailnet
- Fetches Web Finder manifests from devices where Web Finder is installed and running
- Scans local services only on the device running Web Finder
- Opens URLs in your default browser when you tap a service

## Data storage

- Your Tailscale OAuth Client ID and Client Secret are stored locally on your device using the system defaults storage
- No data is sent to any third-party server, analytics service, or tracking platform
- No usage data, crash reports, or telemetry of any kind is collected

## Network access

- The app connects to `api.tailscale.com` to authenticate with Tailscale and retrieve your device list
- The app connects directly to Web Finder manifest endpoints on your Tailscale devices, normally on port `9321`
- The app connects to service URLs on your tailnet or local network when you open them
- The iOS app does not port-scan Tailscale peers; peer services are published by Web Finder running on those peers

## Third-party services

The app uses the Tailscale API solely to discover your devices. Tailscale's own privacy policy applies to their service: https://tailscale.com/privacy-policy

## Contact

If you have questions about this privacy policy, open an issue at https://github.com/zeulewan/web-finder/issues

*Last updated: May 13, 2026*
