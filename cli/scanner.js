/**
 * Shared scanning logic - used by both the desktop app and CLI.
 */
const { exec } = require('child_process');
const net   = require('net');
const http  = require('http');
const https = require('https');

const SCAN_PORTS = [
  80, 443,
  1880,             // Node-RED
  3000, 3001, 3100, 3460,
  4000, 4001, 4173,
  5000, 5001, 5050, 5173, // Synology, pgAdmin, Vite
  6006, 6052,       // TensorBoard, ESPHome
  7860,             // Gradio
  8000, 8001, 8002, 8003, 8004, 8005,
  8006,             // Proxmox
  8080, 8081, 8082,
  8096,             // Jellyfin
  8123,             // Home Assistant
  8443,
  8880, 8881,       // Zensical
  8888,             // Jupyter
  9000, 9001,
  9090, 9093,       // Prometheus, Alertmanager
  9321,             // Web Finder manifest server
  9443,
  11434,            // Ollama
  18789,            // OpenClaw gateway
  19999,            // Netdata
  32400,            // Plex
];
const PORT_TIMEOUT  = 600;
const HTTP_TIMEOUT  = 1000;
const READ_LIMIT    = 16384; // stop reading after 16KB (enough for <title>)

const TAILSCALE_PATHS = [
  'tailscale',
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/usr/local/bin/tailscale',
  '/opt/homebrew/bin/tailscale',
  '/volume1/@appstore/Tailscale/bin/tailscale',
];

// ---- helpers ----------------------------------------------------------------

function execPromise(cmd, timeout = 6000) {
  return new Promise((resolve) => {
    exec(cmd, { timeout }, (err, stdout) => resolve(err ? null : stdout.trim()));
  });
}

function resolveHost(host) {
  return new Promise((resolve) => {
    if (!host) { resolve(false); return; }
    require('dns').lookup(host, (err) => resolve(!err));
  });
}

function checkPort(host, port) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    socket.setTimeout(PORT_TIMEOUT);
    socket.on('connect', () => { socket.destroy(); resolve(true); });
    socket.on('timeout', () => { socket.destroy(); resolve(false); });
    socket.on('error',   () => resolve(false));
    socket.connect(port, host);
  });
}

async function scanPorts(host, ports = SCAN_PORTS) {
  const checks = await Promise.all(
    ports.map(port => checkPort(host, port).then(open => ({ port, open })))
  );
  return checks.filter(c => c.open).map(c => c.port);
}

// Batched port scan for mobile/VPN peers — avoids flooding WireGuard tunnels
async function scanPortsBatched(host, ports = SCAN_PORTS, batchSize = 5) {
  const results = [];
  for (let i = 0; i < ports.length; i += batchSize) {
    const batch = ports.slice(i, i + batchSize);
    const checks = await Promise.all(
      batch.map(port => checkPort(host, port).then(open => ({ port, open })))
    );
    results.push(...checks);
  }
  return results.filter(c => c.open).map(c => c.port);
}


const HTTPS_FIRST_PORTS = new Set([443, 3460, 8443, 9443, 18789]);

const KNOWN_SERVICES = {
  21:    'FTP',
  22:    'SSH',
  25:    'SMTP',
  53:    'DNS',
  1880:  'Node-RED',
  5353:  'mDNS',
  6006:  'TensorBoard',
  6052:  'ESPHome',
  8006:  'Proxmox',
  8096:  'Jellyfin',
  8123:  'Home Assistant',
  9090:  'Prometheus',
  9093:  'Alertmanager',
  9321:  'Web Finder',
  11434: 'Ollama',
  18789: 'OpenClaw',
  19999: 'Netdata',
  32400: 'Plex',
};

const MAC_ONLY_SERVICES = {
  5000: 'AirPlay',
};

// Ports that serve APIs/protocols, not web UIs (hidden unless --all)
const NON_WEB_PORTS = new Set([22, 25, 53, 111, 5353, 11434]); // SSH, SMTP, DNS, portmapper, mDNS, Ollama API
const DARWIN_NON_WEB_PORTS = new Set([5000]); // AirPlay Receiver

function isMacOS(os) {
  if (!os) return false;
  const lower = os.toLowerCase();
  return lower === 'darwin' || lower === 'macos';
}

/** Try http then https (or https first for known HTTPS ports).
 *  Returns { title, url } or null.
 *  Shows ports with HTML but no <title> (SPAs, auth pages) using fallback names. */
async function fetchService(host, port, { isDarwin = false, showAll = false } = {}) {
  const schemes = HTTPS_FIRST_PORTS.has(port) ? ['https', 'http'] : ['http', 'https'];
  let openPortUrl = null;

  for (const scheme of schemes) {
    const url    = `${scheme}://${host}:${port}`;
    const result = await fetchWithRedirect(url);
    if (!result) continue;  // connection failed, try next scheme
    if (result.redirectPort && result.redirectPort !== port) return null;
    if (result.directoryListing && !showAll) return null;
    if (result.title) return { title: result.title, url: result.url || url, directoryListing: result.directoryListing };
    // Port is open but no title - remember URL for fallback
    if (result.noTitle) openPortUrl = openPortUrl || result.url;
    if (result.responded) openPortUrl = openPortUrl || url;
  }

  // Port open but no <title> (SPA, auth-protected, API endpoint)
  if (openPortUrl) {
    const lookup = isDarwin ? { ...KNOWN_SERVICES, ...MAC_ONLY_SERVICES } : KNOWN_SERVICES;
    return { title: lookup[port] ?? `Port ${port}`, url: openPortUrl };
  }

  // Port closed - only show with --all
  if (!showAll) return null;
  const lookup = isDarwin ? { ...KNOWN_SERVICES, ...MAC_ONLY_SERVICES } : KNOWN_SERVICES;
  const scheme = HTTPS_FIRST_PORTS.has(port) ? 'https' : 'http';
  return { title: lookup[port] ?? `Port ${port}`, url: `${scheme}://${host}:${port}` };
}

/** Fetch URL, detect redirects to different ports on same host.
 *  Returns:
 *    { title, url }        - found HTML <title>
 *    { redirectPort }      - redirect to different port
 *    { noTitle: true, url } - HTTP 200 with HTML but no <title> (SPA/auth page)
 *    { responded: true }   - port open but non-HTML or HTTP 4xx/5xx
 *    null                  - connection failed (port closed/timeout) */
function fetchWithRedirect(urlStr) {
  return new Promise((resolve) => {
    const mod = urlStr.startsWith('https') ? https : http;
    let buf = '';
    let settled = false;
    const done = (val) => { if (!settled) { settled = true; resolve(val); } };
    const srcUrl = new URL(urlStr);

    const finalize = () => {
      const m = buf.match(/<title[^>]*>([^<]*)<\/title>/i);
      if (m) {
        const title = cleanTitle(decodeEntities(m[1].trim()));
        const directoryListing = isDirectoryListingTitle(title) || looksLikeDirectoryListing(buf);
        done(title ? { title, url: urlStr, directoryListing } : { noTitle: true, url: urlStr, directoryListing });
        return;
      }
      if (looksLikeDirectoryListing(buf)) {
        done({ title: 'Index of /', url: urlStr, directoryListing: true });
        return;
      }
      const lower = buf.substring(0, 2000).toLowerCase();
      const isHTML = lower.includes('<html') || lower.includes('<!doctype') ||
                     lower.includes('<head') || lower.includes('<body');
      done(isHTML ? { noTitle: true, url: urlStr } : { responded: true });
    };

    const req = mod.get(urlStr, {
      timeout: HTTP_TIMEOUT,
      rejectUnauthorized: false,
      headers: { 'User-Agent': 'web-finder/1.0' },
    }, (res) => {
      // Check for redirect
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        try {
          const loc = new URL(res.headers.location, urlStr);
          const redirPort = parseInt(loc.port) || (loc.protocol === 'https:' ? 443 : 80);
          const srcPort = parseInt(srcUrl.port) || (srcUrl.protocol === 'https:' ? 443 : 80);
          res.destroy();
          if (loc.hostname === srcUrl.hostname && redirPort !== srcPort) {
            done({ redirectPort: redirPort });
          } else {
            // Same-port path redirect — follow it
            fetchWithRedirect(loc.toString()).then(done);
          }
          return;
        } catch {}
      }
      if (res.statusCode >= 400) { res.destroy(); done({ responded: true }); return; }

      res.on('data', (chunk) => {
        buf += chunk;
        const m = buf.match(/<title[^>]*>([^<]*)<\/title>/i);
        if (m) {
          const title = cleanTitle(decodeEntities(m[1].trim()));
          const directoryListing = isDirectoryListingTitle(title) || looksLikeDirectoryListing(buf);
          req.destroy();
          done(title ? { title, url: urlStr, directoryListing } : { noTitle: true, url: urlStr, directoryListing });
          return;
        }
        if (buf.length > READ_LIMIT) { req.destroy(); finalize(); }
      });
      res.on('end', finalize);
    });
    req.on('error',   () => done(null));
    req.on('timeout', () => { req.destroy(); done(null); });
  });
}

function isDirectoryListingTitle(title = '') {
  const normalized = String(title).trim().replace(/\s+/g, ' ');
  return /^Index of(?:\s+\/.*)?$/i.test(normalized) ||
         /^Directory listing for\s+\/.*$/i.test(normalized);
}

function looksLikeDirectoryListing(html = '') {
  const sample = String(html).slice(0, READ_LIMIT);
  const lower = sample.toLowerCase();
  let score = 0;

  if (/<title[^>]*>\s*index of\s+\//i.test(sample)) score += 3;
  if (/index of\s+\//i.test(sample)) score += 1;
  if (lower.includes('parent directory')) score += 2;
  if (/<a\s+href=["']\.\.\/?["']/i.test(sample)) score += 2;
  if (/(last modified|name|size|description)\s*<\/a>/i.test(sample)) score += 1;
  if (/<table[^>]*>[\s\S]{0,4000}<a\s+href=/i.test(sample)) score += 1;
  if (/nginx|apache|lighttpd|uhttpd/i.test(sample) && lower.includes('index of')) score += 1;

  return score >= 3;
}

function isDirectoryListingService(service) {
  return Boolean(service?.directoryListing) || isDirectoryListingTitle(service?.title);
}

function cleanTitle(str) {
  // MkDocs/zensical: "Page Title - Site Name" -> use site name (last part)
  const sep = str.match(/\s+[-–—|]\s+/);
  if (sep) {
    const parts = str.split(sep[0]);
    if (parts.length >= 2) return parts[parts.length - 1].trim();
  }
  return str;
}

function decodeEntities(str) {
  return str
    .replace(/&amp;/g,  '&')
    .replace(/&lt;/g,   '<')
    .replace(/&gt;/g,   '>')
    .replace(/&#39;/g,  "'")
    .replace(/&quot;/g, '"')
    .replace(/&nbsp;/g, ' ')
    .replace(/&#160;/g, ' ');
}

/** Remove HTTP port when HTTPS counterpart exists, and clean up generic "Port X" entries. */
function dedup(services) {
  const pairs = [[80, 443], [5000, 5001], [8080, 8443]];
  const skip = new Set();
  for (const [httpPort, httpsPort] of pairs) {
    if (services.find(s => s.port === httpPort) && services.find(s => s.port === httpsPort)) {
      skip.add(httpPort);
    }
  }
  // Remove generic "Port X" entries for common redirect ports when real titles exist
  const hasRealTitle = services.some(s => !s.title.startsWith('Port '));
  if (hasRealTitle) {
    for (const s of services) {
      if (s.title.startsWith('Port ') && (s.port === 80 || s.port === 443)) {
        skip.add(s.port);
      }
    }
  }
  return services.filter(s => !skip.has(s.port));
}

// ---- local scan -------------------------------------------------------------

/**
 * Scan the local machine.
 * Uses pgrep to identify zensical processes (fast, no TCC delay),
 * then port-scans and fetches HTTP titles for everything else.
 * Returns: [{ title, host, port, url }]
 */
async function scanLocal({ showAll = false } = {}) {
  // Get pgrep hints: port -> project name
  const hints = {};
  const pgrepOut = await execPromise('pgrep -fl zensical 2>/dev/null');
  if (pgrepOut) {
    for (const line of pgrepOut.split('\n')) {
      if (!line.includes('serve')) continue;
      const devAddr  = line.match(/--dev-addr\s+[\d.]+:(\d+)/);
      const portFlag = line.match(/(?:--port|-p)\s+(\d+)/);
      const port     = devAddr ? parseInt(devAddr[1]) : portFlag ? parseInt(portFlag[1]) : 8000;
      const pathM    = line.match(/\/([^/\s]+)\/.venv\/bin\/zensical/);
      hints[port]    = pathM ? pathM[1] : 'zensical';
    }
  }

  // TCP-scan all ports
  const openPorts = (await scanPorts('127.0.0.1'))
    .filter(port => port !== MANIFEST_PORT);

  // Fetch title for each open port (use hint as title if available)
  const services = await Promise.all(openPorts.map(async (port) => {
    if (hints[port]) {
      return { title: hints[port], host: '127.0.0.1', port, url: `http://127.0.0.1:${port}` };
    }
    const isDarwin = process.platform === 'darwin';
    const svc = await fetchService('127.0.0.1', port, { isDarwin, showAll });
    if (!svc) return null;
    return { title: svc.title, host: '127.0.0.1', port, url: svc.url, directoryListing: svc.directoryListing };
  }));

  let result = dedup(services.filter(Boolean));
  if (!showAll) {
    const isDarwin = process.platform === 'darwin';
    result = result.filter(s => {
      if (NON_WEB_PORTS.has(s.port)) return false;
      if (isDarwin && DARWIN_NON_WEB_PORTS.has(s.port)) return false;
      return true;
    });
  }
  return result;
}

// ---- gateway scan -----------------------------------------------------------

async function scanGateway({ showAll = false } = {}) {
  const routeOut = process.platform === 'darwin'
    ? await execPromise('route -n get default 2>/dev/null')
    : await execPromise('ip route show default 2>/dev/null');
  if (!routeOut) return null;

  let ip;
  if (process.platform === 'darwin') {
    const m = routeOut.match(/gateway:\s*([\d.]+)/);
    ip = m ? m[1] : null;
  } else {
    const m = routeOut.match(/via\s+([\d.]+)/);
    ip = m ? m[1] : null;
  }
  if (!ip) return null;

  const gatewayPorts = [80, 443, 8080, 8443];
  const openPorts = await scanPorts(ip, gatewayPorts);
  if (openPorts.length === 0) return null;

  // Fetch with showAll, rename generic "Port X" fallbacks to "Admin Page"
  const services = await Promise.all(openPorts.map(async (port) => {
    const svc = await fetchService(ip, port, { showAll: true });
    if (!svc) return null;
    const title = svc.title.startsWith('Port ') ? 'Admin Page' : svc.title;
    return { title, host: ip, port, url: svc.url, directoryListing: svc.directoryListing };
  }));

  const found = dedup(services.filter(Boolean))
    .filter(s => showAll || !isDirectoryListingService(s));
  if (found.length === 0) return null;
  // Detect hardware model (e.g. "UniFi Express") then fall back to ISP, page title, etc.
  const model = await detectUnifiModel(ip);
  const isp = await getISPName();
  const realTitle = found.find(s => !s.title.startsWith('Port ') && s.title !== 'Admin Page')?.title;
  const name = model || (isp ? `${isp} Modem` : null) || realTitle || 'Gateway';
  // For UniFi devices, only keep port 443 (port 80 redirects, 8080 is device inform)
  let finalServices = found;
  if (model) {
    const filtered = found.filter(s => s.port === 443);
    finalServices = filtered.length > 0 ? filtered : found;
  }
  return { name, ip, services: finalServices };
}

/** Detect UniFi hardware model from UNIFI_OS_MANIFEST in the gateway page. */
function detectUnifiModel(host) {
  return new Promise((resolve) => {
    let buf = '';
    const req = https.get(`https://${host}`, {
      timeout: 3000,
      rejectUnauthorized: false,
      headers: { 'User-Agent': 'web-finder/1.0' },
    }, (res) => {
      res.on('data', (chunk) => {
        buf += chunk;
        if (buf.length > 16384) { req.destroy(); }
        const m = buf.match(/UNIFI_OS_MANIFEST\s*=\s*(\{[^<]*\})/);
        if (m) {
          req.destroy();
          try {
            const manifest = JSON.parse(m[1]);
            resolve(manifest.model?.shortName || manifest.model?.longName || null);
          } catch { resolve(null); }
        }
      });
      res.on('end', () => resolve(null));
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

async function getISPName() {
  return new Promise((resolve) => {
    const req = https.get('https://ipinfo.io/json', { timeout: 3000 }, (res) => {
      let buf = '';
      res.on('data', (c) => { buf += c; });
      res.on('end', () => {
        try {
          const org = JSON.parse(buf).org || '';
          resolve(org.replace(/^AS\d+\s+/, '') || null);
        } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
  });
}

// ---- Tailscale scan ---------------------------------------------------------

async function getTailscaleStatus() {
  const out = await execTailscale('status --json 2>/dev/null');
  if (out) {
    try { return JSON.parse(out); } catch {}
  }
  return null;
}

function tailscaleBackendError(status) {
  const state = String(status?.BackendState || '').trim();
  if (!state || state.toLowerCase() === 'running') return null;
  if (state.toLowerCase() === 'needslogin') {
    return 'Tailscale is signed out';
  }
  return `Tailscale is ${state}`;
}

async function execTailscale(args, timeout = 6000) {
  for (const tsPath of TAILSCALE_PATHS) {
    const out = await execPromise(`"${tsPath}" ${args}`, timeout);
    if (out) return out;
  }
  return null;
}

/**
 * Scan all online Tailscale peers.
 * Returns: { peers: [{ name, ip, online, services: [{ title, port, url }] }] }
 */
async function scanTailscale({ showAll = false } = {}) {
  const status = await getTailscaleStatus();
  if (!status) return { error: 'Tailscale not available', peers: [] };
  const backendError = tailscaleBackendError(status);
  if (backendError) return { error: backendError, peers: [] };
  if (!status.Peer) return { peers: [] };

  const peers = Object.values(status.Peer)
    .map(peer => {
      const hn   = peer.HostName || '';
      const rawDNS = (peer.DNSName || '').replace(/\.$/, '');  // strip trailing dot
      const dnsName = rawDNS || null;
      const dn   = rawDNS.split('.')[0] || '';
      const name = (!hn || hn.toLowerCase() === 'localhost') ? (dn || 'unknown') : hn.replace(/\..*$/, '');
      const ip   = (peer.TailscaleIPs || [])[0];
      return { name, ip, dnsName: dnsName || ip, online: peer.Online || false, os: peer.OS || null };
    })
    .filter(p => p.ip);

  const dnsWarning = status.Self?.DNSName
    ? !(await resolveHost((status.Self.DNSName || '').replace(/\.$/, '')))
    : false;

  const scanned = await Promise.all(peers.map(async (peer) => {
    if (!peer.online) return { ...peer, services: [] };

    // Use manifest — peers without web-finder serve show no services
    const isDarwin  = isMacOS(peer.os);
    const manifest = await fetchManifest(peer.dnsName, peer.ip);
    const services = (manifest && Array.isArray(manifest.services))
      ? manifest.services.filter(s => s.port && s.url).map(s => {
          // Rewrite localhost URLs to use peer's actual hostname (URLs in manifest are 127.0.0.1)
          let url = s.url;
          try {
            const u = new URL(s.url);
            if (u.hostname === '127.0.0.1' || u.hostname === 'localhost') {
              u.hostname = peer.dnsName;
              url = u.toString();
            }
          } catch {}
          return { title: s.name || `Port ${s.port}`, port: s.port, url, directoryListing: s.directoryListing };
        })
      : [];

    let result = dedup(services.filter(Boolean));
    if (!showAll) {
      result = result.filter(s => {
        if (NON_WEB_PORTS.has(s.port)) return false;
        if (isDarwin && DARWIN_NON_WEB_PORTS.has(s.port)) return false;
        if (isDirectoryListingService(s)) return false;
        return true;
      });
    }
    const warnings = [];
    if (manifest?.usedIpSniFallback) {
      warnings.push(`MagicDNS failed for ${peer.dnsName}; used Tailscale IP fallback for discovery`);
    }
    return { ...peer, services: result, warnings };
  }));

  const warnings = [];
  if (dnsWarning) {
    warnings.push('Tailscale MagicDNS is not resolving on this machine; run `tailscale set --accept-dns=true` for clickable .ts.net links.');
  }

  return { peers: scanned, warnings };
}

// ---- manifest server (Linux: ss-based dynamic discovery) --------------------

const MANIFEST_PORT    = 9321;
const MANIFEST_PATH    = '/.well-known/web-finder.json';
const LOOPBACK_ADDRS   = new Set(['127.0.0.1', '127.0.0.54', '::1']);

/**
 * Parse `ss -tlnp` output and return all ports that are network-accessible
 * (bound to 0.0.0.0, ::, or a specific non-loopback address).
 * Returns: [{ port, process }]
 */
async function getListeningPortsSS() {
  const out = await execPromise('ss -tlnp --no-header 2>/dev/null');
  if (!out) return [];

  const portMap = new Map(); // port -> { process, accessible }
  for (const line of out.split('\n')) {
    const m = line.match(/LISTEN\s+\d+\s+\d+\s+([\d.:[\]*]+):(\d+)\s/);
    if (!m) continue;
    const addr = m[1].replace(/[[\]]/g, '');
    const port = parseInt(m[2]);
    if (!port) continue;

    const isLoopback  = LOOPBACK_ADDRS.has(addr);
    const isBindAll   = addr === '0.0.0.0' || addr === '::' || addr === '*';
    const accessible  = !isLoopback || isBindAll;

    const procM = line.match(/users:\(\("([^"]+)"/);
    const proc  = procM ? procM[1] : null;

    if (!portMap.has(port)) {
      portMap.set(port, { process: proc, accessible });
    } else if (accessible) {
      const entry = portMap.get(port);
      entry.accessible = true;
      if (!entry.process && proc) entry.process = proc;
    }
  }

  return Array.from(portMap.entries())
    .filter(([, info]) => info.accessible)
    .map(([port, info]) => ({ port, process: info.process }));
}

/**
 * Scan the local machine using `ss` to discover all listening ports dynamically.
 * Linux-only. Falls back to scanLocal on macOS.
 * In tailnetOnly mode, only returns services already mapped by Tailscale Serve.
 * Returns: [{ title, host, port, url }]
 */
async function scanLocalSS({ showAll = false, tailnetOnly = false } = {}) {
  if (tailnetOnly) return scanTailscaleServedLocal({ showAll });

  if (process.platform !== 'linux') {
    const services = await scanLocal({ showAll });
    return services;
  }

  const [listeningPorts, tsServeMap, zensicalHints] = await Promise.all([
    getListeningPortsSS(),
    getTailscaleServeMap(),
    getZensicalHints(),
  ]);
  if (listeningPorts.length === 0) return scanLocal({ showAll });

  const services = await Promise.all(listeningPorts.map(async ({ port, process: procName }) => {
    // If we have a zensical project name hint, use it (better than ss process names)
    const hint = zensicalHints[port];
    const svc = await fetchService('127.0.0.1', port, { isDarwin: false, showAll: true });
    if (!svc) {
      // Port open but fetchService got nothing - use hint if available
      if (hint) return { title: hint, host: '127.0.0.1', port, url: `http://127.0.0.1:${port}` };
      return null;
    }
    // Use zensical hint or ss process name when fetchService returns a generic "Port N"
    const title = svc.title.startsWith('Port ') ? (hint || procName || svc.title) : svc.title;

    // For manifests, advertise the Tailscale Serve HTTPS URL. For local CLI
    // output, keep the directly reachable localhost URL.
    let url = svc.url;
    const extPort = tsServeMap.get(port);
    if (extPort && tailnetOnly) {
      try {
        const u = new URL(url);
        u.protocol = 'https:';
        u.port = extPort;
        url = u.toString();
      } catch {}
    }

    return { title, host: '127.0.0.1', port: (tailnetOnly && extPort) ? extPort : port, url, directoryListing: svc.directoryListing };
  }));

  let result = dedup(services.filter(Boolean))
    .filter(s => s.port !== MANIFEST_PORT);
  if (tailnetOnly) {
    result = result.filter(s => {
      try {
        const u = new URL(s.url);
        return u.protocol === 'https:' && u.hostname === '127.0.0.1';
      } catch {
        return false;
      }
    });
  }
  if (!showAll) {
    result = result.filter(s => {
      if (NON_WEB_PORTS.has(s.port)) return false;
      if (isDirectoryListingService(s)) return false;
      // Exclude generic "Port N" fallbacks — no real web UI, just an open port
      if (s.title === `Port ${s.port}`) return false;
      return true;
    });
  }
  return result;
}

/**
 * Build a map of port -> project name for zensical processes on Linux.
 * Uses pgrep to find zensical PIDs, reads /proc/PID/cwd for the working directory,
 * and extracts the port from command-line flags.
 * Returns: { port: projectName }
 */
async function getZensicalHints() {
  const hints = {};
  const out = await execPromise('pgrep -fa zensical 2>/dev/null');
  if (!out) return hints;

  const fs = require('fs');
  for (const line of out.split('\n')) {
    if (!line.includes('serve')) continue;
    const pidM = line.match(/^(\d+)\s/);
    if (!pidM) continue;
    const pid = pidM[1];

    const devAddr  = line.match(/--dev-addr\s+[\d.]+:(\d+)/);
    const portFlag = line.match(/(?:--port|-p|-a)\s+[\d.]*:?(\d+)/);
    const port     = devAddr ? parseInt(devAddr[1]) : portFlag ? parseInt(portFlag[1]) : 8000;

    // Try .venv path first (e.g. /project/.venv/bin/zensical -> "project")
    const pathM = line.match(/\/([^/\s]+)\/.venv\/bin\/zensical/);
    if (pathM) {
      hints[port] = pathM[1];
      continue;
    }

    // Fall back to working directory basename via /proc/PID/cwd
    try {
      const cwd = fs.readlinkSync(`/proc/${pid}/cwd`);
      const basename = cwd.split('/').filter(Boolean).pop();
      if (basename) hints[port] = basename;
    } catch {}
  }
  return hints;
}

/**
 * Parse `tailscale serve status` to find ports with HTTPS proxies.
 * Returns a Map of localPort -> externalPort.
 * Tailscale serve terminates TLS on the Tailscale interface, so remote
 * clients must use https:// with the DNS name for these ports.
 */
async function getTailscaleServeMap() {
  const map = new Map(); // localPort -> externalPort
  const out = await execTailscale('serve status 2>/dev/null');
  if (!out) return map;

  let extPort = null;
  for (const line of out.split('\n')) {
    // Match: https://hostname.ts.net:PORT (tailnet only)
    // Default HTTPS (port 443) has no :PORT suffix
    const extM = line.match(/^https:\/\/[^/]+?(?::(\d+))?\s+\(tailnet/);
    if (extM) {
      extPort = extM[1] ? parseInt(extM[1]) : 443;
      continue;
    }
    // Match: |-- / proxy http://localhost:PORT
    // Also handle HTTPS backends served as https+insecure://127.0.0.1:PORT.
    const proxyM = line.match(/proxy\s+https?(?:\+insecure)?:\/\/(?:localhost|127\.0\.0\.1):(\d+)/);
    if (proxyM && extPort !== null) {
      map.set(parseInt(proxyM[1]), extPort);
      extPort = null;
    }
  }
  return map;
}

async function scanTailscaleServedLocal({ showAll = false } = {}) {
  const tsServeMap = await getTailscaleServeMap();
  const services = await Promise.all(Array.from(tsServeMap.entries()).map(async ([localPort, externalPort]) => {
    if (localPort === MANIFEST_PORT) return null;

    const isDarwin = process.platform === 'darwin';
    const svc = await fetchService('127.0.0.1', localPort, { isDarwin, showAll });
    if (!svc) return null;

    let url = svc.url;
    try {
      const u = new URL(url);
      u.protocol = 'https:';
      u.hostname = '127.0.0.1';
      u.port = externalPort;
      url = u.toString();
    } catch {
      url = `https://127.0.0.1:${externalPort}`;
    }

    return { title: svc.title, host: '127.0.0.1', port: externalPort, localPort, url, directoryListing: svc.directoryListing };
  }));

  let result = dedup(services.filter(Boolean));
  if (!showAll) {
    const isDarwin = process.platform === 'darwin';
    result = result.filter(s => {
      if (NON_WEB_PORTS.has(s.localPort) || NON_WEB_PORTS.has(s.port)) return false;
      if (isDarwin && (DARWIN_NON_WEB_PORTS.has(s.localPort) || DARWIN_NON_WEB_PORTS.has(s.port))) return false;
      if (isDirectoryListingService(s)) return false;
      if (s.title === `Port ${s.localPort}` || s.title === `Port ${s.port}`) return false;
      return true;
    });
  }
  return result;
}

/**
 * Fetch the web-finder manifest from a peer.
 * Returns parsed manifest object or null if not available.
 */
function fetchManifest(host, fallbackHost = null) {
  return new Promise((resolve) => {
    const candidates = [
      host && { scheme: 'https', connectHost: host },
      host && { scheme: 'http', connectHost: host },
      // Tailscale Serve requires the MagicDNS hostname for HTTPS SNI/Host,
      // but Linux peers may have accept-dns disabled. Connect to the IP while
      // preserving the DNSName at the TLS/HTTP layer.
      host && fallbackHost && { scheme: 'https', connectHost: fallbackHost, virtualHost: host },
      fallbackHost && { scheme: 'http', connectHost: fallbackHost },
      fallbackHost && { scheme: 'https', connectHost: fallbackHost },
    ].filter(Boolean);
    const seen = new Set();
    const endpoints = candidates.filter(candidate => {
        const key = `${candidate.scheme}://${candidate.connectHost}:${MANIFEST_PORT}|${candidate.virtualHost || ''}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });

    const tryEndpoint = (idx) => {
      if (idx >= endpoints.length) { resolve(null); return; }
      const endpoint = endpoints[idx];
      const mod = endpoint.scheme === 'https' ? https : http;
      const options = {
        protocol: `${endpoint.scheme}:`,
        hostname: endpoint.connectHost,
        port: MANIFEST_PORT,
        path: MANIFEST_PATH,
        timeout: 3500,
        rejectUnauthorized: false,
        headers: {},
      };
      if (endpoint.virtualHost) {
        options.servername = endpoint.virtualHost;
        options.headers.Host = `${endpoint.virtualHost}:${MANIFEST_PORT}`;
      }
      const req = mod.get(options, (res) => {
        if (res.statusCode !== 200) { res.resume(); tryEndpoint(idx + 1); return; }
        let buf = '';
        res.on('data', (c) => {
          buf += c;
          if (buf.length > 65536) {
            req.destroy();
            resolve(null);
          }
        });
        res.on('end', () => {
          try {
            const manifest = JSON.parse(buf);
            if (endpoint.virtualHost) manifest.usedIpSniFallback = true;
            resolve(manifest);
          } catch { tryEndpoint(idx + 1); }
        });
      });
      req.on('error',   () => tryEndpoint(idx + 1));
      req.on('timeout', () => { req.destroy(); tryEndpoint(idx + 1); });
    };

    tryEndpoint(0);
  });
}

module.exports = {
  scanLocal, scanLocalSS, scanTailscale, scanGateway,
  scanPorts, scanPortsBatched, checkPort,
  getListeningPortsSS, getTailscaleServeMap, fetchManifest,
  SCAN_PORTS, MANIFEST_PORT, MANIFEST_PATH,
};
