# Web Finder

**Find web interfaces across your network.**

Stop bookmarking admin pages, docs sites, and test builds. Web Finder discovers every web service on your Tailscale peers, one click away.

**[zeulewan.github.io/web-finder](https://zeulewan.github.io/web-finder/)**

![Web Finder](docs/app-screenshot.png)

## Platforms

| | Platform | What you get |
|---|---|---|
| **macOS** | Menubar app + CLI | `curl -sSL https://raw.githubusercontent.com/zeulewan/web-finder/main/install.sh \| bash` |
| **Linux** | CLI | Same install command (auto-installs Node.js if missing) |
| **iOS** | iPhone + iPad | [App Store](https://apps.apple.com/app/web-finder-for-tailscale/id6759476914) (free) |

## CLI

```
web-finder                 Full scan (local + Tailscale)
web-finder --local         Local machine only
web-finder --tailscale     Tailscale peers only
web-finder --all           Include non-web ports (SSH, AirPlay, etc.)
web-finder --json          JSON output for scripts and agents
```

## What it scans

TCP-scans common ports, fetches HTTP `<title>` tags, and identifies running services.

```
80  443  3000  3001  4000  4001  5000  5001  6006  7860
8000-8005  8080-8082  8443  8888  9000  9001  9090  9443
```

Catches dev servers, NAS UIs, Jupyter notebooks, Grafana, Prometheus, Gradio, and anything else serving a web page.

## Project structure

```
macos/   Menubar app (Swift/SwiftUI)
ios/     iPhone + iPad app (Swift/SwiftUI)
cli/     CLI (Node.js)
docs/    Website (GitHub Pages)
```

## License

MIT
