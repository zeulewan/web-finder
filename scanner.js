/**
 * Shared scanning logic - used by both the desktop app and CLI.
 */
const { exec } = require('child_process');
const net = require('net');

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
const PORT_TIMEOUT = 900;

const TAILSCALE_PATHS = [
  'tailscale',
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/usr/local/bin/tailscale',
  '/opt/homebrew/bin/tailscale',
];

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
    socket.on('error', () => resolve(false));
    socket.connect(port, host);
  });
}

async function scanPorts(host, ports = SCAN_PORTS) {
  const checks = await Promise.all(
    ports.map(port => checkPort(host, port).then(open => ({ port, open })))
  );
  return checks.filter(c => c.open).map(c => c.port);
}

// Find zensical processes via pgrep (fast, no TCC delay).
// Parses --dev-addr HOST:PORT or --port PORT flags.
async function scanLocal() {
  const out = await execPromise('pgrep -fl zensical 2>/dev/null');
  if (!out) return [];

  const results = [];
  for (const line of out.split('\n')) {
    if (!line.includes('zensical') || !line.includes('serve')) continue;
    if (line.includes('grep')) continue;

    const devAddrMatch = line.match(/--dev-addr\s+([\d.]+):(\d+)/);
    const portFlagMatch = line.match(/(?:--port|-p)\s+(\d+)/);

    const port = devAddrMatch
      ? parseInt(devAddrMatch[2])
      : portFlagMatch
      ? parseInt(portFlagMatch[1])
      : 8000;

    // Extract project name from virtualenv path: /GIT/myproject/.venv/bin/zensical
    const pathMatch = line.match(/\/([^/\s]+)\/.venv\/bin\/zensical/);
    const project = pathMatch ? pathMatch[1] : 'local';

    results.push({
      project,
      host: '127.0.0.1',
      port,
      url: `http://127.0.0.1:${port}`,
    });
  }
  return results;
}

async function getTailscaleStatus() {
  for (const tsPath of TAILSCALE_PATHS) {
    const out = await execPromise(`"${tsPath}" status --json 2>/dev/null`);
    if (!out) continue;
    try { return JSON.parse(out); } catch {}
  }
  return null;
}

async function scanTailscale() {
  const status = await getTailscaleStatus();
  if (!status) return { error: 'Tailscale not available', peers: [] };
  if (!status.Peer) return { peers: [] };

  const peers = Object.values(status.Peer)
    .map(peer => {
      const hn = peer.HostName || '';
      const dn = (peer.DNSName || '').replace(/\..*$/, '');
      const name = (!hn || hn.toLowerCase() === 'localhost') ? (dn || 'unknown') : hn.replace(/\..*$/, '');
      return { name, ip: (peer.TailscaleIPs || [])[0], online: peer.Online || false };
    })
    .filter(p => p.ip);

  const scanned = await Promise.all(
    peers.map(async (peer) => {
      if (!peer.online) return { ...peer, ports: [] };
      const ports = await scanPorts(peer.ip);
      return { ...peer, ports };
    })
  );

  return { peers: scanned };
}

module.exports = { scanLocal, scanTailscale, scanPorts, checkPort, SCAN_PORTS };
