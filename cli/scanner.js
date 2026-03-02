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
  8888,             // Jupyter
  9000, 9001,
  9090, 9093,       // Prometheus, Alertmanager
  9443,
  11434,            // Ollama
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
];

// ---- helpers ----------------------------------------------------------------

function execPromise(cmd, timeout = 6000) {
  return new Promise((resolve) => {
    exec(cmd, { timeout }, (err, stdout) => resolve(err ? null : stdout.trim()));
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


const HTTPS_FIRST_PORTS = new Set([443, 3460, 8443, 9443]);

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
  11434: 'Ollama',
  19999: 'Netdata',
  32400: 'Plex',
};

const MAC_ONLY_SERVICES = {
  5000: 'AirPlay',
};

// Ports that serve APIs/protocols, not web UIs (hidden unless --all)
const NON_WEB_PORTS = new Set([11434]); // Ollama API
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
    if (result.title) return { title: result.title, url: result.url || url };
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
        done(title ? { title, url: urlStr } : { noTitle: true, url: urlStr });
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
      // Check for redirect to different port on same host
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        try {
          const loc = new URL(res.headers.location, urlStr);
          const redirPort = parseInt(loc.port) || (loc.protocol === 'https:' ? 443 : 80);
          if (loc.hostname === srcUrl.hostname && redirPort !== parseInt(srcUrl.port || (srcUrl.protocol === 'https:' ? 443 : 80))) {
            res.destroy();
            done({ redirectPort: redirPort });
            return;
          }
        } catch {}
      }
      if (res.statusCode >= 400) { res.destroy(); done({ responded: true }); return; }

      res.on('data', (chunk) => {
        buf += chunk;
        const m = buf.match(/<title[^>]*>([^<]*)<\/title>/i);
        if (m) {
          const title = cleanTitle(decodeEntities(m[1].trim()));
          req.destroy();
          done(title ? { title, url: urlStr } : { noTitle: true, url: urlStr });
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
  const openPorts = await scanPorts('127.0.0.1');

  // Fetch title for each open port (use hint as title if available)
  const services = await Promise.all(openPorts.map(async (port) => {
    if (hints[port]) {
      return { title: hints[port], host: '127.0.0.1', port, url: `http://127.0.0.1:${port}` };
    }
    const isDarwin = process.platform === 'darwin';
    const svc = await fetchService('127.0.0.1', port, { isDarwin, showAll });
    if (!svc) return null;
    return { title: svc.title, host: '127.0.0.1', port, url: svc.url };
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
    return { title, host: ip, port, url: svc.url };
  }));

  const found = dedup(services.filter(Boolean));
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
  for (const tsPath of TAILSCALE_PATHS) {
    const out = await execPromise(`"${tsPath}" status --json 2>/dev/null`);
    if (!out) continue;
    try { return JSON.parse(out); } catch {}
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

  const scanned = await Promise.all(peers.map(async (peer) => {
    if (!peer.online) return { ...peer, services: [] };

    // Scan using IP (fast), build URLs with MagicDNS name (valid HTTPS certs)
    const openPorts = await scanPorts(peer.ip);
    const isDarwin = isMacOS(peer.os);
    const services  = await Promise.all(openPorts.map(async (port) => {
      // Try MagicDNS name first (valid HTTPS certs); fall back to IP if DNS doesn't resolve
      let svc = await fetchService(peer.dnsName, port, { isDarwin, showAll });
      if (!svc && peer.ip !== peer.dnsName) svc = await fetchService(peer.ip, port, { isDarwin, showAll });
      if (!svc) return null;
      return { title: svc.title, port, url: svc.url };
    }));

    let result = dedup(services.filter(Boolean));
    if (!showAll) {
      result = result.filter(s => {
        if (NON_WEB_PORTS.has(s.port)) return false;
        if (isDarwin && DARWIN_NON_WEB_PORTS.has(s.port)) return false;
        return true;
      });
    }
    return { ...peer, services: result };
  }));

  return { peers: scanned };
}

module.exports = { scanLocal, scanTailscale, scanGateway, scanPorts, checkPort, SCAN_PORTS };
