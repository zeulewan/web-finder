# Privacy Policy

**Web Finder** does not collect, store, or transmit any personal data.

## What the app does

- Connects to the Tailscale API using OAuth credentials you provide to discover devices on your tailnet
- Scans discovered devices for open web ports over your local/Tailscale network
- Opens URLs in your default browser when you tap a service

## Data storage

- Your Tailscale OAuth Client ID and Client Secret are stored locally on your device using the system defaults storage
- No data is sent to any third-party server, analytics service, or tracking platform
- No usage data, crash reports, or telemetry of any kind is collected

## Network access

- The app connects to `api.tailscale.com` to authenticate with Tailscale and retrieve your device list
- The app makes direct TCP connections to your Tailscale peers to scan for open ports and fetch web page titles
- No other network connections are made

## Third-party services

The app uses the Tailscale API solely to discover your devices. Tailscale's own privacy policy applies to their service: https://tailscale.com/privacy-policy

## Contact

If you have questions about this privacy policy, open an issue at https://github.com/zeulewan/web-finder/issues

*Last updated: February 20, 2026*
