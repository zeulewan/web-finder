const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  scan:          ()  => ipcRenderer.invoke('scan'),
  openUrl:       (u) => ipcRenderer.send('open-url', u),
  quit:          ()  => ipcRenderer.send('quit'),
  setHeight:     (h) => ipcRenderer.send('set-height', h),
  onTriggerScan: (cb) => ipcRenderer.on('trigger-scan', cb),
});
