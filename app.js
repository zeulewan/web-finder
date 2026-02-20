let scanning = false;

function ts() {
  const d = new Date();
  return [d.getHours(), d.getMinutes(), d.getSeconds()]
    .map(n => n.toString().padStart(2, '0'))
    .join(':');
}

function makeEntry({ dot, name, sub, port, url }) {
  const el = document.createElement('div');
  el.className = 'entry';
  el.innerHTML = `
    <span class="dot dot-${dot}"></span>
    <span class="entry-name">${name}${sub ? `<span class="entry-sub"> ${sub}</span>` : ''}</span>
    ${port != null ? `<span class="entry-port">:${port}</span>` : ''}
    ${url ? `<button class="open-btn" data-url="${url}">Open →</button>` : ''}
  `;
  if (url) {
    el.querySelector('.open-btn').addEventListener('click', () => window.api.openUrl(url));
  }
  return el;
}

function renderLocal(local) {
  const el = document.getElementById('local-list');
  el.innerHTML = '';
  if (!local || local.length === 0) {
    el.innerHTML = '<div class="empty">No instances running</div>';
    return;
  }
  for (const inst of local) {
    el.appendChild(makeEntry({ dot: 'green', name: inst.project, port: inst.port, url: inst.url }));
  }
}

function renderTailscale({ error, peers }) {
  const el = document.getElementById('tailscale-list');
  el.innerHTML = '';

  if (error) {
    el.innerHTML = `<div class="empty err">${error}</div>`;
    return;
  }
  if (!peers || peers.length === 0) {
    el.innerHTML = '<div class="empty">No peers found</div>';
    return;
  }

  for (const peer of peers) {
    if (!peer.online) {
      el.appendChild(makeEntry({ dot: 'grey', name: peer.name }));
      continue;
    }
    if (peer.ports.length === 0) {
      el.appendChild(makeEntry({ dot: 'yellow', name: peer.name, sub: 'online' }));
      continue;
    }
    for (const port of peer.ports) {
      el.appendChild(makeEntry({ dot: 'green', name: peer.name, port, url: `http://${peer.ip}:${port}` }));
    }
  }
}

function adjustHeight() {
  const h = document.getElementById('app').scrollHeight + 2;
  window.api.setHeight(h);
}

async function doScan() {
  if (scanning) return;
  scanning = true;

  document.getElementById('local-list').innerHTML = '<div class="empty muted">Scanning...</div>';
  document.getElementById('tailscale-list').innerHTML = '<div class="empty muted">Scanning...</div>';
  document.getElementById('refresh').classList.add('spinning');
  adjustHeight();

  try {
    const { local, tailscale } = await window.api.scan();
    renderLocal(local);
    renderTailscale(tailscale);
    document.getElementById('timestamp').textContent = ts();
    adjustHeight();
  } catch (e) {
    document.getElementById('local-list').innerHTML = `<div class="empty err">${e.message}</div>`;
  } finally {
    scanning = false;
    document.getElementById('refresh').classList.remove('spinning');
  }
}

document.getElementById('refresh').addEventListener('click', doScan);
document.getElementById('quit').addEventListener('click', () => window.api.quit());
window.api.onTriggerScan(doScan);

doScan();
