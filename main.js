const {
  app, BrowserWindow, ipcMain, Tray, nativeImage, shell, screen, Menu,
} = require('electron');
const path = require('path');
const { scanLocal, scanTailscale } = require('./scanner');

// ── Tray icon (radar rings, drawn as BGRA bitmap) ────────────────────────────
function createTrayIcon() {
  const px = 36; // 18pt @ 2x Retina
  const buf = Buffer.alloc(px * px * 4, 0);
  const cx = px / 2 - 0.5;
  const cy = px / 2 - 0.5;

  for (let y = 0; y < px; y++) {
    for (let x = 0; x < px; x++) {
      const i = (y * px + x) * 4;
      const r = Math.sqrt((x - cx) ** 2 + (y - cy) ** 2);
      let a = 0;
      if (r >= 15 && r <= 17) a = 220;       // outer ring
      else if (r >= 9.5 && r <= 11.5) a = 175; // mid ring
      else if (r >= 4.5 && r <= 6.5) a = 130;  // inner ring
      else if (r <= 2.2) a = 255;               // center dot
      if (a > 0) { buf[i] = 255; buf[i+1] = 255; buf[i+2] = 255; buf[i+3] = a; }
    }
  }

  const img = nativeImage.createFromBitmap(buf, { width: px, height: px, scaleFactor: 2 });
  img.setTemplateImage(true);
  return img;
}

// ── Window ───────────────────────────────────────────────────────────────────
let tray, win;
let lastHiddenTime = 0;

function createWindow() {
  win = new BrowserWindow({
    width: 340,
    height: 420,
    show: false,
    frame: false,
    resizable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
  });

  win.loadFile('index.html');

  // Hide when clicking outside
  win.on('blur', () => {
    lastHiddenTime = Date.now();
    win.hide();
  });
}

function positionWindow() {
  const tb = tray.getBounds();
  const wb = win.getBounds();
  const display = screen.getDisplayNearestPoint({ x: tb.x, y: tb.y });
  const wa = display.workArea;

  let x = Math.round(tb.x + tb.width / 2 - wb.width / 2);
  const y = tb.y + tb.height + 2;

  // Clamp horizontally so the window stays on screen
  x = Math.max(wa.x + 4, Math.min(x, wa.x + wa.width - wb.width - 4));
  win.setPosition(x, y, false);
}

// ── IPC ──────────────────────────────────────────────────────────────────────
ipcMain.handle('scan', async () => {
  const [local, tailscale] = await Promise.all([scanLocal(), scanTailscale()]);
  return { local, tailscale };
});

ipcMain.on('open-url', (_, url) => shell.openExternal(url));
ipcMain.on('quit', () => app.quit());

// Renderer tells us its content height so we can resize the window to fit
ipcMain.on('set-height', (_, h) => {
  const clamped = Math.min(560, Math.max(180, h));
  const [w] = win.getSize();
  win.setSize(w, clamped, false);
  positionWindow();
});

// ── App ──────────────────────────────────────────────────────────────────────
app.whenReady().then(() => {
  app.dock.hide();

  tray = new Tray(createTrayIcon());
  tray.setToolTip('Zensical Scanner');

  // Right-click context menu
  tray.setContextMenu(Menu.buildFromTemplate([
    {
      label: 'Refresh', click: () => {
        if (win.isVisible()) win.webContents.send('trigger-scan');
      },
    },
    { type: 'separator' },
    { label: 'Quit', click: () => app.quit() },
  ]));

  // Left-click to toggle popup
  tray.on('click', () => {
    if (win.isVisible()) {
      lastHiddenTime = Date.now();
      win.hide();
      return;
    }
    // Guard against blur → click race (blur fires before click on macOS)
    if (Date.now() - lastHiddenTime < 150) return;
    positionWindow();
    win.show();
    win.focus();
    win.webContents.send('trigger-scan');
  });

  createWindow();

  // Auto-refresh every 30s while popup is open
  setInterval(() => {
    if (win?.isVisible()) win.webContents.send('trigger-scan');
  }, 30000);
});

app.on('window-all-closed', () => {}); // Keep running in tray
