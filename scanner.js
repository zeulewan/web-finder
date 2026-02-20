/**
 * Shared scanning logic - used by both the desktop app and CLI.
 */
const { exec } = require('child_process');
const net   = require('net');
const http  = require('http');
const https = require('https');

const SCAN_PORTS = [
  80, 443,
  3000, 3001,
  4000, 4001,
  5000, 5001,       // Synology DSM
  6006,             // TensorBoard
  7860,             // Gradio
  8000, 8001, 8002, 8003, 8004, 8005,
  8080, 8081, 8082,
  8443,
  8888,             // Jupyter
  9000, 9001,
  9090,             // Prometheus
  9443,
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

/** Fetch the HTML <title> from a URL. Returns null on failure or error response. */
function fetchTitle(urlStr) {
  return new Promise((resolve) => {
    const mod = urlStr.startsWith('https') ? https : http;
    let buf = '';
    let settled = false;
    const done = (val) => { if (!settled) { settled = true; resolve(val); } };

    const req = mod.get(urlStr, {
      timeout: HTTP_TIMEOUT,
      rejectUnauthorized: false,   // accept self-signed certs (Synology, etc.)
      headers: { 'User-Agent': 'web-finder/1.0' },
    }, (res) => {
      // If the server rejects the scheme (e.g. HTTP sent to HTTPS port), skip it
      if (res.statusCode >= 400) { res.destroy(); done(null); return; }

      res.on('data', (chunk) => {
        buf += chunk;
        if (buf.length > READ_LIMIT) { req.destroy(); }
        // Early exit once we have the title
        const m = buf.match(/<title[^>]*>([^<]*)<\/title>/i);
        if (m) { req.destroy(); done(decodeEntities(m[1].trim()) || null); }
      });
      res.on('end', () => done(null));
    });
    req.on('error',   () => done(null));
    req.on('timeout', () => { req.destroy(); done(null); });
  });
}

const HTTPS_FIRST_PORTS = new Set([443, 8443, 9443]);

const KNOWN_SERVICES = {
  21:   'FTP',
  22:   'SSH',
  25:   'SMTP',
  53:   'DNS',
  5353: 'mDNS',
  6006: 'TensorBoard',
  9090: 'Prometheus',
};

const MAC_ONLY_SERVICES = {
  5000: 'AirPlay',
};

/** Try http then https (or https first for known HTTPS ports); return { title, url } or null. */
async function fetchService(host, port, isDarwin = false) {
  const schemes = HTTPS_FIRST_PORTS.has(port) ? ['https', 'http'] : ['http', 'https'];
  for (const scheme of schemes) {
    const url   = `${scheme}://${host}:${port}`;
    const title = await fetchTitle(url);
    if (title) return { title, url };
  }
  const lookup = isDarwin ? { ...KNOWN_SERVICES, ...MAC_ONLY_SERVICES } : KNOWN_SERVICES;
  if (lookup[port]) {
    return { title: lookup[port], url: `http://${host}:${port}` };
  }
  return null;
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

// ---- local scan -------------------------------------------------------------

/**
 * Scan the local machine.
 * Uses pgrep to identify zensical processes (fast, no TCC delay),
 * then port-scans and fetches HTTP titles for everything else.
 * Returns: [{ title, host, port, url }]
 */
async function scanLocal() {
  // Get pgrep hints: port -> project name
  const hints = {};
  const pgrepOut = await execPromise('pgrep -fl zensical 2>/dev/null');
  if (pgrepOut) {
    for (const line of pgrepOut.split('\n')) {
      if (!line.includes('serve') || line.includes('grep')) continue;
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
    const svc = await fetchService('127.0.0.1', port, true); // local is always darwin
    if (!svc) return null;
    return { title: svc.title, host: '127.0.0.1', port, url: svc.url };
  }));

  return services.filter(Boolean);
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
async function scanTailscale() {
  const status = await getTailscaleStatus();
  if (!status) return { error: 'Tailscale not available', peers: [] };
  if (!status.Peer) return { peers: [] };

  const peers = Object.values(status.Peer)
    .map(peer => {
      const hn   = peer.HostName || '';
      const dn   = (peer.DNSName || '').replace(/\..*$/, '');
      const name = (!hn || hn.toLowerCase() === 'localhost') ? (dn || 'unknown') : hn.replace(/\..*$/, '');
      return { name, ip: (peer.TailscaleIPs || [])[0], online: peer.Online || false, os: peer.OS || null };
    })
    .filter(p => p.ip);

  const scanned = await Promise.all(peers.map(async (peer) => {
    if (!peer.online) return { ...peer, services: [] };

    const openPorts = await scanPorts(peer.ip);
    const services  = await Promise.all(openPorts.map(async (port) => {
      const isDarwin = (peer.os || '').toLowerCase() === 'darwin';
      const svc = await fetchService(peer.ip, port, isDarwin);
      return svc
        ? { title: svc.title, port, url: svc.url }
        : { title: `Port ${port}`, port, url: `http://${peer.ip}:${port}` };
    }));

    return { ...peer, services };
  }));

  return { peers: scanned };
}

module.exports = { scanLocal, scanTailscale, scanPorts, checkPort, SCAN_PORTS };
