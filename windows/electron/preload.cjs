const { contextBridge, ipcRenderer, webUtils } = require("electron");
contextBridge.exposeInMainWorld("island", {
  snapshot: () => ipcRenderer.invoke("snapshot"),
  call: (method, args = {}) => ipcRenderer.invoke("call", method, args),
  surface: (value) => ipcRenderer.send("surface", value),
  dragFile: (path) => ipcRenderer.send("drag-file", path),
  filePath: (file) => webUtils.getPathForFile(file),
  on: (callback) => {
    const handler = (_, name, data) => callback(name, data);
    ipcRenderer.on("event", handler);
    return () => ipcRenderer.removeListener("event", handler);
  },
});
