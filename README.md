# zensical-scanner

Menubar app + CLI for finding running Zensical servers - locally and across Tailscale.

## Desktop App

```bash
npm install
npm start
```

A radar icon appears in your menu bar. Click it to see all running Zensical instances. Click **Open →** to launch in your browser. Auto-refreshes every 30 seconds while open.

## CLI

The CLI is useful for scripts and agents (Claude Code, etc.).

```bash
# Full scan - local + Tailscale
node bin/zensical-scan

# Local processes only
node bin/zensical-scan --local

# Tailscale peers only
node bin/zensical-scan --tailscale

# JSON output (for agents/scripts)
node bin/zensical-scan --json
node bin/zensical-scan --local --json
```

### Install globally

```bash
npm install -g .
zensical-scan --local --json
```

### Multi-machine setup

Install on each Tailscale machine so agents can call it locally:

```bash
# On each machine (workstation, etc.)
git clone <repo>
cd zensical-scanner
npm install -g .
```

Then any agent on any machine can run `zensical-scan --json` to get a machine-readable list of what's running locally.

## How it works

- **Local**: Parses `ps aux` for `zensical serve` processes and extracts the port from `--dev-addr` or `--port` flags, plus the project name from the virtualenv path.
- **Tailscale**: Queries `tailscale status --json` for peers, then TCP-scans common ports (3000, 4000, 5000, 8000-8004, 8080-8081, 8888) in parallel on each online peer.

## Ports scanned

`3000, 4000, 5000, 8000, 8001, 8002, 8003, 8004, 8080, 8081, 8888`
