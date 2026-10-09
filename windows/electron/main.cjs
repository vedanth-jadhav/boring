const {
  app,
  BrowserWindow,
  ipcMain,
  screen,
  Tray,
  Menu,
  nativeImage,
  globalShortcut,
  dialog,
  shell,
  Notification,
  nativeTheme,
} = require("electron");
const path = require("node:path");
const fs = require("node:fs");
const { NativeClient } = require("./native-client.cjs");

let window,
  tray,
  backend,
  poll,
  quitting = false,
  helperStopped = false,
  expanded = false,
  pointer = false,
  ignoring = false,
  fullscreenHidden = false;
let rectangle = { x: 238, y: 0, width: 204, height: 34, radius: 17 };
const state = {
  settings: null,
  windows: process.platform === "win32",
  media: {},
  lyrics: { lines: [] },
  focus: {},
  shelf: [],
  artwork: "",
  battery: "",
  material: true,
};
const nativeMethods = new Set([
  "settings",
  "view",
  "media",
  "lyrics",
  "focus",
  "caffeine",
  "calendar",
  "calendar-remove",
  "reminder-add",
  "reminder-done",
  "shelf-add",
  "shelf-remove",
  "zip",
  "pdf",
  "image",
  "share",
  "volume",
  "mute",
  "brightness",
  "system",
  "usage",
  "quota",
  "mirror",
]);
const dataRoot =
  process.env.BORING_DATA_HOME ||
  path.join(
    process.platform === "win32"
      ? process.env.LOCALAPPDATA
      : app.getPath("appData"),
    "BoringNotch",
  );
fs.mkdirSync(path.join(dataRoot, "Electron"), { recursive: true });
app.setPath("userData", path.join(dataRoot, "Electron"));
if (process.platform === "win32") app.setAppUserModelId("BoringNotch.Octave");
if (!app.requestSingleInstanceLock()) app.exit(0);
app.on("second-instance", () => {
  window?.show();
  window?.webContents.send("event", "open", true);
});

function emit(name, value) {
  if (window && !window.isDestroyed())
    window.webContents.send("event", name, value);
}
function settingsChanged(settings) {
  state.settings = settings;
  if (process.platform === "win32" && app.isPackaged)
    app.setLoginItemSettings({
      openAtLogin: settings.startAtLogin,
      path: process.execPath,
      args: ["--background"],
    });
  place();
}
function place() {
  if (!window || window.isDestroyed()) return;
  const displays = screen.getAllDisplays();
  const display =
    displays[Math.min(state.settings?.monitor || 0, displays.length - 1)] ||
    screen.getPrimaryDisplay();
  const work = display.workArea;
  const width = Math.min(680, work.width - 16);
  const height = Math.min(650, work.height - 16);
  const mode = state.settings?.placement || "floating";
  window.setBounds({
    x: Math.round(
      mode === "corner"
        ? work.x + work.width - width - 8
        : work.x + (work.width - width) / 2,
    ),
    y: work.y + (mode === "edge" ? 0 : 8),
    width,
    height,
  });
  emit("viewport", {
    width,
    height,
    displays: displays.map((d, i) => ({
      index: i,
      width: d.size.width,
      height: d.size.height,
      scale: d.scaleFactor,
    })),
  });
}
function shape(rect) {
  if (process.platform !== "win32" || !window) return;
  const x = Math.round(rect.x),
    y = Math.round(rect.y),
    w = Math.max(1, Math.round(rect.width)),
    h = Math.max(1, Math.round(rect.height));
  const radius = Math.max(
    0,
    Math.min(Math.round(rect.radius), Math.floor(h / 2)),
  );
  const regions = [];
  if (rect.edge) {
    const t = Math.min(19, Math.floor(h / 2)),
      b = Math.min(32, Math.floor(h / 2));
    for (let row = 0; row < t; row++) {
      const u = Math.sqrt((row + 0.5) / t),
        inset = Math.round(t * (2 * u - u * u));
      regions.push({
        x: x + inset,
        y: y + row,
        width: Math.max(1, w - inset * 2),
        height: 1,
      });
    }
    regions.push({
      x: x + t,
      y: y + t,
      width: Math.max(1, w - t * 2),
      height: Math.max(1, h - t - b),
    });
    for (let row = 0; row < b; row++) {
      const inset = Math.round(
        t + b * Math.pow(1 - Math.sqrt(1 - (row + 0.5) / b), 2),
      );
      regions.push({
        x: x + inset,
        y: y + h - b + row,
        width: Math.max(1, w - inset * 2),
        height: 1,
      });
    }
  } else {
    regions.push({
      x,
      y: y + radius,
      width: w,
      height: Math.max(1, h - radius * 2),
    });
    for (let row = 0; row < radius; row++) {
      const inset = Math.round(
        radius * Math.pow(1 - Math.sqrt((row + 0.5) / radius), 2),
      );
      regions.push(
        {
          x: x + inset,
          y: y + row,
          width: Math.max(1, w - inset * 2),
          height: 1,
        },
        {
          x: x + inset,
          y: y + h - row - 1,
          width: Math.max(1, w - inset * 2),
          height: 1,
        },
      );
    }
  }
  try {
    window.setShape(regions);
  } catch {
    /* CSS clipping remains available if native shaping fails. */
  }
}
function startBackend() {
  const helper = path.join(
    process.resourcesPath,
    "native",
    "BoringWindowsHelper.exe",
  );
  const development = path.resolve(
    __dirname,
    "..",
    "Boring.Native",
    "bin",
    "Release",
    process.platform === "win32" ? "net10.0-windows10.0.19041.0" : "net10.0",
    "BoringWindowsHelper.dll",
  );
  backend = app.isPackaged
    ? new NativeClient(helper, ["--service"], {
        env: { ...process.env, BORING_DATA_HOME: dataRoot },
      })
    : new NativeClient(
        process.env.DOTNET_HOST || "dotnet",
        [development, "--service"],
        { env: { ...process.env, BORING_DATA_HOME: dataRoot } },
      );
  backend.on("event", (name, data) => {
    if (name === "ready") {
      state.windows = data.windows;
      settingsChanged(data.settings);
      emit("ready", { ...state, settings: data.settings });
      const handle = window.getNativeWindowHandle();
      void backend
        .call("owner", {
          handle: (handle.length >= 8
            ? handle.readBigUInt64LE()
            : BigInt(handle.readUInt32LE())
          ).toString(),
        })
        .catch((error) => emit("notice", error.message));
      if (process.argv.includes("--enable-startup"))
        void backend
          .call("settings", { startAtLogin: true })
          .catch((error) => emit("notice", error.message));
    } else if (name === "settings") {
      settingsChanged(data);
      emit(name, data);
    } else if (name === "fullscreen") {
      if (data && window.isVisible()) {
        fullscreenHidden = true;
        window.hide();
        emit("visibility", false);
      } else if (!data && fullscreenHidden) {
        fullscreenHidden = false;
        window.showInactive();
        emit("visibility", true);
      }
    } else {
      if (name === "material")
        data =
          data &&
          !nativeTheme.shouldUseHighContrastColors &&
          !nativeTheme.prefersReducedTransparency;
      if (name in state) state[name] = data;
      if (name === "focusComplete" || name === "reminder") {
        if (Notification.isSupported())
          new Notification({
            title: name === "focusComplete" ? "Focus complete" : "Reminder",
            body:
              name === "focusComplete"
                ? "Take a moment to recharge."
                : String(data),
          }).show();
        window.showInactive();
        emit("open", name === "focusComplete" ? "focus" : "calendar");
      }
      emit(name, data);
    }
  });
  backend.on("notice", (message) => emit("notice", message));
  backend.on("diagnostic", (message) => console.error(message));
  backend.on("close", (reason) => {
    helperStopped = true;
    if (!quitting) emit("notice", reason + " Quit and restart to reconnect.");
  });
}

app.whenReady().then(async () => {
  nativeTheme.themeSource = "dark";
  window = new BrowserWindow({
    width: 680,
    height: 650,
    frame: false,
    transparent: true,
    resizable: false,
    maximizable: false,
    minimizable: false,
    show: false,
    skipTaskbar: true,
    hasShadow: false,
    alwaysOnTop: true,
    backgroundColor: "#00000000",
    title: "Boring Notch Octave",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      backgroundThrottling: true,
      spellcheck: false,
    },
  });
  window.setAlwaysOnTop(true, "screen-saver");
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.on("close", (event) => {
    if (!quitting) {
      event.preventDefault();
      window.hide();
      emit("visibility", false);
    }
  });
  screen.on("display-added", place);
  screen.on("display-removed", place);
  screen.on("display-metrics-changed", place);
  ipcMain.handle("snapshot", (event) => {
    if (event.sender !== window.webContents) throw new Error("Invalid window.");
    return {
      ...state,
      viewport: {
        width: window.getBounds().width,
        height: window.getBounds().height,
        displays: screen.getAllDisplays().map((d, i) => ({
          index: i,
          width: d.size.width,
          height: d.size.height,
          scale: d.scaleFactor,
        })),
      },
    };
  });
  ipcMain.handle("call", async (event, method, args = {}) => {
    if (event.sender !== window.webContents) throw new Error("Invalid window.");
    if (nativeMethods.has(method)) return backend.call(method, args);
    if (method === "add-files" || method === "import-calendar") {
      const options = {
        properties: ["openFile", "multiSelections"],
        title:
          method === "add-files" ? "Add files to shelf" : "Import calendar",
        ...(method === "import-calendar"
          ? { filters: [{ name: "Calendar", extensions: ["ics"] }] }
          : {}),
      };
      const selection = await dialog.showOpenDialog(window, options);
      if (!selection.canceled)
        return backend.call(
          method === "add-files" ? "shelf-add" : "calendar-import",
          { paths: selection.filePaths },
        );
      return null;
    }
    if (method === "save-copies") {
      const selection = await dialog.showOpenDialog(window, {
        title: "Save shelf copies",
        properties: ["openDirectory", "createDirectory"],
      });
      if (!selection.canceled)
        return backend.call("save-copies", {
          paths: args.paths,
          folder: selection.filePaths[0],
        });
      return null;
    }
    if (method === "screenshot") {
      window.hide();
      emit("visibility", false);
      await new Promise((resolve) => setTimeout(resolve, 220));
      try {
        return await backend.call("screenshot");
      } finally {
        window.showInactive();
        emit("visibility", true);
      }
    }
    if (method === "open-file" || method === "reveal-file") {
      if (!state.shelf.some((item) => item.path === args.path))
        throw new Error("That shelf copy is unavailable.");
      if (method === "open-file") {
        const error = await shell.openPath(args.path);
        if (error) throw new Error(error);
      } else shell.showItemInFolder(args.path);
      return true;
    }
    if (method === "windows-settings") {
      if (process.platform !== "win32")
        throw new Error("This shortcut requires Windows.");
      const allowed = {
        sound: "ms-settings:sound",
        camera: "ms-settings:privacy-webcam",
        bluetooth: "ms-settings:bluetooth",
      };
      if (!allowed[args.page]) throw new Error("Unknown settings page.");
      return shell.openExternal(allowed[args.page]);
    }
    if (method === "hide") {
      window.hide();
      emit("visibility", false);
      return true;
    }
    if (method === "quit") {
      app.quit();
      return true;
    }
    throw new Error("Unknown operation.");
  });
  ipcMain.on("surface", (event, value) => {
    if (
      event.sender !== window.webContents ||
      !value ||
      !["x", "y", "width", "height", "radius"].every((key) =>
        Number.isFinite(value[key]),
      )
    )
      return;
    const bounds = window.getBounds();
    rectangle = {
      x: Math.max(0, Math.min(bounds.width, value.x)),
      y: Math.max(0, Math.min(bounds.height, value.y)),
      width: Math.min(bounds.width, Math.max(1, value.width)),
      height: Math.min(bounds.height, Math.max(1, value.height)),
      radius: Math.max(0, value.radius),
      edge: !!value.edge,
    };
    expanded = !!value.expanded;
    shape(rectangle);
  });
  ipcMain.on("drag-file", (event, file) => {
    if (
      event.sender !== window.webContents ||
      !state.shelf.some((item) => item.path === file) ||
      !fs.existsSync(file)
    )
      return;
    event.sender.startDrag({
      file,
      icon: nativeImage
        .createFromPath(path.join(__dirname, "assets", "octave.png"))
        .resize({ width: 32, height: 32 }),
    });
  });
  await window.loadFile(path.join(__dirname, "renderer", "index.html"));
  place();
  startBackend();
  if (!process.argv.includes("--background")) window.showInactive();
  try {
    tray = new Tray(
      nativeImage
        .createFromPath(path.join(__dirname, "assets", "icon.png"))
        .resize({ width: 20, height: 20 }),
    );
    tray.setToolTip("Boring Notch Octave · Ctrl+Windows+B");
    tray.setContextMenu(
      Menu.buildFromTemplate([
        {
          label: "Show island",
          click: () => {
            window.show();
            emit("open", true);
          },
        },
        {
          label: "Settings",
          click: () => {
            window.show();
            emit("open", "settings");
          },
        },
        { type: "separator" },
        { label: "Quit", click: () => app.quit() },
      ]),
    );
    tray.on("click", () => {
      window.show();
      emit("open", true);
    });
  } catch (error) {
    console.error("Tray unavailable:", error.message);
  }
  if (
    !globalShortcut.register("Control+Super+B", () => {
      if (window.isVisible()) {
        window.hide();
        emit("visibility", false);
      } else {
        window.show();
        emit("visibility", true);
      }
    })
  )
    emit(
      "notice",
      "Ctrl+Windows+B is already in use. The tray can always reopen the island.",
    );
  async function checkPointer() {
    if (quitting || window.isDestroyed()) return;
    if (window.isVisible()) {
      const point =
        (process.platform === "linux" && !helperStopped
          ? await backend.call("development-cursor").catch(() => null)
          : null) || screen.getCursorScreenPoint();
      if (quitting || window.isDestroyed()) return;
      const bounds = window.getBounds();
      const x = point.x - bounds.x - rectangle.x,
        y = point.y - bounds.y - rectangle.y;
      let inside =
        x >= 0 && y >= 0 && x <= rectangle.width && y <= rectangle.height;
      const radius = Math.min(rectangle.radius, rectangle.height / 2);
      if (inside && radius > 0) {
        const dx = Math.max(radius - x, 0, x - (rectangle.width - radius));
        const dy = Math.max(radius - y, 0, y - (rectangle.height - radius));
        inside = dx * dx + dy * dy <= radius * radius;
      }
      if (ignoring !== !inside) {
        ignoring = !inside;
        window.setIgnoreMouseEvents(ignoring, { forward: true });
      }
      if (inside !== pointer) {
        pointer = inside;
        emit("pointer", inside);
      }
    }
    poll = setTimeout(checkPointer, expanded ? 16 : 60);
  }
  nativeTheme.on("updated", () => {
    if (process.platform === "win32" && !helperStopped) {
      const handle = window.getNativeWindowHandle();
      void backend
        .call("owner", {
          handle: (handle.length >= 8
            ? handle.readBigUInt64LE()
            : BigInt(handle.readUInt32LE())
          ).toString(),
        })
        .catch((error) => emit("notice", error.message));
    }
  });
  checkPointer();
});
app.on("before-quit", (event) => {
  quitting = true;
  clearTimeout(poll);
  globalShortcut.unregisterAll();
  if (backend && !helperStopped) {
    event.preventDefault();
    backend.close();
    backend.once("close", () => app.quit());
    setTimeout(() => {
      backend.child.kill();
      helperStopped = true;
      app.quit();
    }, 3000).unref();
  }
});
app.on("window-all-closed", () => {
  if (quitting) app.quit();
});
