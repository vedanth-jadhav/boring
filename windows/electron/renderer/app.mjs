import {
  Spring,
  notchPath,
  playbackPosition,
  currentLine,
} from "./geometry.mjs";

const $ = (selector) => document.querySelector(selector);
const e = (value) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        char
      ],
  );
const paths = {
  home: '<path d="m3 10 9-7 9 7M5 9v11h5v-6h4v6h5V9"/>',
  shelf: '<path d="M4 9 7 4h10l3 5v11H4Z"/><path d="M4 11h5l2 3h2l2-3h5"/>',
  timer:
    '<circle cx="12" cy="13" r="8"/><path d="M12 9v5l3 2M9 2h6M18 5l2 2"/>',
  terminal:
    '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m6 8 3 3-3 3m6 1h5"/>',
  gear: '<path d="m9.5 3-.7 2-2 .8-2-.5L3 8l1.5 1.5v2L3 13l1.8 2.7 2-.5 2 .8.7 2h3l.7-2 2-.8 2 .5L21 13l-1.5-1.5v-2L21 8l-1.8-2.7-2 .5-2-.8-.7-2Z"/><circle cx="12" cy="10.5" r="3"/>',
  play: '<path d="m7 3 14 9-14 9Z" fill="currentColor" stroke="none"/>',
  pause:
    '<rect x="6" y="3" width="4" height="18" rx=".7" fill="currentColor" stroke="none"/><rect x="14" y="3" width="4" height="18" rx=".7" fill="currentColor" stroke="none"/>',
  previous:
    '<path d="m12 5-10 7 10 7Zm10 0-10 7 10 7Z" fill="currentColor" stroke="none"/>',
  next: '<path d="m2 5 10 7-10 7Zm10 0 10 7-10 7Z" fill="currentColor" stroke="none"/>',
  volume:
    '<path d="M3 9h4l5-4v14l-5-4H3Z" fill="currentColor" stroke="none"/><path d="M16 8a6 6 0 0 1 0 8m3-11a10 10 0 0 1 0 14"/>',
  heart: '<path d="M12 20 4 12C-2 5 8 1 12 7c4-6 14-2 8 5Z"/>',
  coffee:
    '<path d="M4 8h13v6a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5ZM17 8h2a3 3 0 0 1 0 6h-2M2 22h19M7 2v3m4-3v3m4-3v3"/>',
  calendar:
    '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4m10-4v4M3 10h18M7 14h3m4 0h3m-10 4h3"/>',
  camera: '<path d="M3 7h4l2-3h6l2 3h4v13H3Z"/><circle cx="12" cy="13" r="4"/>',
  battery:
    '<rect x="2" y="7" width="18" height="10" rx="2"/><path d="M22 10v4M5 10h10v4H5Z"/>',
  plug: '<path d="M8 2v5m8-5v5M6 7h12v4a6 6 0 0 1-12 0ZM12 17v5"/>',
  check: '<path d="m4 12 5 5L20 6"/>',
  arrow: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  back: '<path d="M20 12H4m6-6-6 6 6 6"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  more: '<circle cx="4" cy="12" r="1" fill="currentColor"/><circle cx="12" cy="12" r="1" fill="currentColor"/><circle cx="20" cy="12" r="1" fill="currentColor"/>',
  music:
    '<path d="M9 17V5l11-2v12M9 5l11-2v4L9 9"/><ellipse cx="6" cy="17" rx="3" ry="2"/><ellipse cx="17" cy="15" rx="3" ry="2"/>',
  folder: '<path d="M3 6h7l2 3h9v11H3Z"/>',
  file: '<path d="M6 2h8l5 5v15H6ZM14 2v6h5M9 13h7m-7 4h7"/>',
  download: '<path d="M12 3v12m-5-5 5 5 5-5M3 16v5h18v-5"/>',
  share: '<path d="M12 16V2m-5 5 5-5 5 5M7 10H3v12h18V10h-4"/>',
  shield:
    '<path d="m12 2 9 4v6c0 6-9 10-9 10S3 18 3 12V6Z"/><path d="m8 12 3 3 5-6"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 1v3m0 16v3M1 12h3m16 0h3M4 4l2 2m12 12 2 2M4 20l2-2M18 6l2-2"/>',
  refresh: '<path d="M20 8a8 8 0 1 0 0 8M20 3v5h-5"/>',
  awake:
    '<path d="M9 3h6M12 3v4"/><circle cx="12" cy="14" r="8"/><path d="M12 10v4l3 2"/>',
};
function icon(name, className = "") {
  return `<svg class="${className}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.file}</svg>`;
}
function action(label, method, args = {}, primary = false) {
  const button = document.createElement("button");
  button.className = "action" + (primary ? " primary" : "");
  button.textContent = label;
  button.onclick = () => run(method, args, button);
  return button;
}
function clock(seconds) {
  const t = Math.max(0, Math.ceil(seconds || 0));
  return `${Math.floor(t / 60)
    .toString()
    .padStart(2, "0")}:${(t % 60).toString().padStart(2, "0")}`;
}
function shortNumber(value) {
  return new Intl.NumberFormat("en", {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(value || 0);
}
let model = {
  settings: null,
  media: {},
  focus: {},
  lyrics: { lines: [] },
  shelf: [],
  artwork: "",
  windows: false,
  viewport: { width: 680, height: 650, displays: [] },
};
let expanded = false,
  visible = true,
  inside = false,
  page = "music",
  wizard = false,
  step = 0,
  choice = [],
  layout = "floating",
  settingsTab = "general",
  focusTab = "timer";
let duration = 25,
  caffeineDuration = 30,
  busy = 0,
  hoverTimeout,
  closeTimeout,
  noticeTimeout,
  osdTimeout,
  osd = "",
  selected = new Set(),
  lastLine,
  lastBackground;
const w = new Spring(204),
  h = new Spring(34),
  openness = new Spring(0, 32),
  art = new Spring(0, 28);
let raf = 0,
  previousFrame = 0;
const motionPreference = matchMedia("(prefers-reduced-motion:reduce)");
const reduced = () =>
  !!model.settings?.reducedMotion || motionPreference.matches;
const groups = [
  {
    id: "music",
    title: "Music & lyrics",
    detail: "Your players, playback and synchronized words",
    icon: "music",
    tab: "home",
  },
  {
    id: "productivity",
    title: "Focus & your day",
    detail: "A timer, stay-awake, calendar and reminders",
    icon: "timer",
    tab: "timer",
  },
  {
    id: "files",
    title: "Files & sharing",
    detail: "A shelf, screenshots and quick file tools",
    icon: "shelf",
    tab: "shelf",
  },
  {
    id: "system",
    title: "Your PC & tools",
    detail: "System controls, mirror and Codex usage",
    icon: "terminal",
    tab: "terminal",
  },
];

async function run(method, args = {}, button = null) {
  busy++;
  if (button) {
    button.classList.add("busy");
    button.setAttribute("aria-busy", "true");
  }
  try {
    return await window.island.call(method, args);
  } catch (error) {
    showNotice(
      String(error.message || error).replace(
        /^Error invoking remote method '[^']+': Error: /,
        "",
      ),
    );
    return null;
  } finally {
    busy--;
    if (button) {
      button.classList.remove("busy");
      button.removeAttribute("aria-busy");
    }
  }
}
function showNotice(text) {
  clearTimeout(noticeTimeout);
  $("#notice").textContent = text;
  $("#notice").hidden = false;
  targetSize();
  noticeTimeout = setTimeout(() => {
    $("#notice").hidden = true;
    targetSize();
  }, 7000);
}
function width() {
  return Math.max(280, Math.min(wizard ? 490 : 640, model.viewport.width - 40));
}
function targetHeight() {
  if (!expanded) return 34;
  if (wizard)
    return Math.min(
      Math.max([464, 350, 396][step], $("#expanded").scrollHeight),
      model.viewport.height - 14,
    );
  const heights = {
    music: 190,
    focus: 232,
    files: 270 + Math.min(model.shelf.length, 4) * 34,
    calendar: 375,
    codex: 330,
    system: 260,
    mirror: 342,
    settings:
      settingsTab === "music" ? 310 : settingsTab === "system" ? 405 : 540,
  };
  return Math.min(
    Math.max(
      (heights[page] || 330) + ($("#notice").hidden ? 0 : 32),
      $("#expanded").scrollHeight,
    ),
    model.viewport.height - 14,
  );
}
function targetSize() {
  document.body.classList.toggle("reduced", reduced());
  document.documentElement.style.setProperty("--open-width", `${width()}px`);
  const snap = reduced();
  w.frequency = expanded ? 28 : 34;
  h.frequency = expanded ? 28 : 34;
  art.frequency = expanded ? 28 : 34;
  w.set(expanded ? width() : 204, snap);
  h.set(targetHeight(), snap);
  openness.set(expanded ? 1 : 0, snap);
  art.set(expanded && page === "music" && !wizard ? 1 : 0, snap);
  $("#expanded").inert = !expanded;
  $("#expanded").classList.toggle("visible", expanded);
  drawGeometry();
  ensureFrame();
}
function drawGeometry() {
  const cw = model.viewport.width,
    mode = wizard ? layout : model.settings?.placement;
  const x = mode === "corner" ? cw - w.value - 20 : (cw - w.value) / 2;
  const y = 0,
    edge = mode === "edge",
    radius = expanded ? 24 : 17;
  const path = notchPath(w.value, h.value, edge, radius);
  $("#silhouette").setAttribute("d", path);
  $("#silhouette").setAttribute("transform", `translate(${x},${y})`);
  $("#silhouette").setAttribute(
    "fill",
    model.settings?.glass === false || model.material === false
      ? "url(#solid)"
      : "url(#glass)",
  );
  $("#shell").style.transform = `translate(${x}px,${y}px)`;
  $("#shell").style.clipPath = `path('${path}')`;
  $("#expanded").style.opacity = String(openness.value);
  $("#expanded").style.transform =
    `translateY(${(-3 * (1 - openness.value)).toFixed(2)}px)`;
  $("#compact").style.opacity = String(Math.max(0, 1 - openness.value * 3));
  $("#compact").inert = expanded;
  const small = 20,
    large = cw < 540 ? 76 : 118,
    a = art.value;
  const artSize = small + (large - small) * a;
  const ax = x + (edge ? 19 : 0) + 7 + (15 - (edge ? 19 : 0)) * a;
  const ay = 7 + 45 * a;
  $("#artwork-clip").style.transform = `translate(${x}px,${y}px)`;
  $("#artwork-clip").style.clipPath = `path('${path}')`;
  $("#artwork").style.transform = `translate(${ax - x}px,${ay - y}px)`;
  $("#artwork").style.width = `${artSize}px`;
  $("#artwork").style.height = `${artSize}px`;
  $("#artwork").style.borderRadius = `${4 + 9 * a}px`;
  $("#artwork").style.opacity =
    wizard || !model.settings?.features.includes("music")
      ? "0"
      : String(
          expanded && page !== "music"
            ? Math.max(0, 1 - openness.value * 4)
            : 1,
        );
  window.island.surface({
    x,
    y,
    width: w.value,
    height: h.value,
    radius: edge ? 0 : radius,
    edge,
    expanded,
  });
}
function ensureFrame() {
  if (!raf) {
    previousFrame = performance.now();
    raf = requestAnimationFrame(frame);
  }
}
function frame(now) {
  raf = 0;
  const delta = Math.min((now - previousFrame) / 1000, 0.05);
  previousFrame = now;
  const moving = w.active || h.active || openness.active || art.active;
  if (moving) {
    w.step(delta);
    h.step(delta);
    openness.step(delta);
    art.step(delta);
    drawGeometry();
  } else if (!previousFrame || reduced()) drawGeometry();
  if (expanded && !wizard && page === "music") updatePlayback();
  if (
    moving ||
    (visible &&
      expanded &&
      page === "music" &&
      model.media.playing &&
      !reduced())
  )
    raf = requestAnimationFrame(frame);
}
function expand(next = null) {
  clearTimeout(hoverTimeout);
  clearTimeout(closeTimeout);
  expanded = true;
  if (next) page = next;
  if (model.settings && !model.settings.onboarded) wizard = true;
  if (!wizard && page !== "settings" && !allowed(page)) page = firstPage();
  renderPage();
  targetSize();
  void run("view", { expanded, page: wizard ? "onboarding" : page });
}
function collapse() {
  if (wizard) return;
  clearTimeout(hoverTimeout);
  clearTimeout(closeTimeout);
  expanded = false;
  targetSize();
  void run("view", { expanded, page });
}
function pointerChanged(value) {
  inside = value;
  clearTimeout(hoverTimeout);
  clearTimeout(closeTimeout);
  if (
    value &&
    !expanded &&
    model.settings?.onboarded &&
    model.settings.hoverOpen
  ) {
    if (w.active) expand();
    else
      hoverTimeout = setTimeout(() => {
        if (inside) expand();
      }, 160);
  } else if (!value && expanded && !wizard && model.settings?.autoCollapse)
    scheduleClose();
}
function scheduleClose() {
  closeTimeout = setTimeout(() => {
    if (inside || !expanded || wizard) return;
    const focused = document.activeElement;
    if (
      busy ||
      ["SELECT", "TEXTAREA"].includes(focused.tagName) ||
      (focused.tagName === "INPUT" &&
        !["checkbox", "radio", "range", "button"].includes(focused.type))
    ) {
      scheduleClose();
      return;
    }
    collapse();
  }, 420);
}
function allowed(value) {
  return model.settings?.features.includes(
    {
      music: "music",
      focus: "productivity",
      calendar: "productivity",
      files: "files",
      codex: "system",
      system: "system",
      mirror: "system",
    }[value],
  );
}
function firstPage() {
  return (
    { music: "music", productivity: "focus", files: "files", system: "codex" }[
      model.settings?.features[0]
    ] || "settings"
  );
}
function go(value) {
  page = value;
  wizard = false;
  expand(value);
}
function renderTabs() {
  $("header").style.display = wizard ? "none" : "";
  const tabs = $("#tabs");
  tabs.replaceChildren();
  const entries = [
    ["music", "home", "Music"],
    ["files", "shelf", "File shelf"],
    ["focus", "timer", "Focus"],
    ["codex", "terminal", "Codex usage"],
  ];
  for (const [value, glyph, label] of entries)
    if (allowed(value)) {
      const button = document.createElement("button");
      button.title = label;
      button.setAttribute("aria-label", label);
      button.setAttribute("aria-current", page === value ? "page" : "false");
      button.dataset.page = value;
      button.innerHTML = icon(glyph);
      button.className = page === value ? "selected" : "";
      button.onclick = () => go(value);
      tabs.append(button);
    }
  $("#settings").innerHTML = icon("gear");
  $("#settings").onclick = () => go("settings");
  $("#settings").classList.toggle("selected", page === "settings");
  updateHeader();
}
function updateHeader() {
  const header = $("#header-status");
  header.replaceChildren();
  const add = (glyph, label, title, fn, className = "") => {
    const button = document.createElement("button");
    button.innerHTML = icon(glyph) + `<span>${e(label)}</span>`;
    button.title = title;
    button.setAttribute("aria-label", title);
    button.className = className;
    button.onclick = fn;
    header.append(button);
  };
  if (model.focus.caffeineSeconds > 0)
    add(
      "coffee",
      clock(model.focus.caffeineSeconds),
      "Stay-awake session",
      () => {
        focusTab = "caffeine";
        go("focus");
      },
      "awake",
    );
  if (model.focus.running || model.focus.paused)
    add("timer", clock(model.focus.seconds), "Current focus session", () =>
      go("focus"),
    );
  else if (allowed("calendar"))
    add("calendar", "", "Calendar and reminders", () => go("calendar"));
  if (allowed("system")) {
    const percentage = (model.battery || "").match(/^(\d+)%/);
    add(
      percentage ? "battery" : "plug",
      percentage ? `${percentage[1]}%` : "",
      model.battery || "System controls",
      () => go("system"),
    );
  }
}
function updateCompact() {
  $("#compact-label").textContent =
    osd ||
    (model.focus.running || model.focus.paused
      ? clock(model.focus.seconds)
      : model.media.title && model.media.title !== "Nothing playing yet"
        ? model.media.title
        : "Boring Notch");
  $("#compact-wave").classList.toggle(
    "playing",
    !!model.media.playing && visible && !reduced(),
  );
  $("#compact-wave").hidden = !allowed("music");
}
function renderPage() {
  $("#expanded").style.paddingBottom =
    page === "music" && !wizard ? "14px" : "18px";
  lastLine = lastBackground = undefined;
  $("#content").replaceChildren();
  renderTabs();
  if (wizard) renderOnboarding();
  else
    (
      ({
        music: renderMusic,
        focus: renderFocus,
        files: renderFiles,
        calendar: renderCalendar,
        codex: renderCodex,
        system: renderSystem,
        mirror: renderMirror,
        settings: renderSettings,
      })[page] || renderSettings
    )();
  targetSize();
  updateCompact();
}
function renderOnboarding() {
  const content = $("#content");
  const section = document.createElement("div");
  section.className = "onboard";
  if (step === 0) {
    section.innerHTML =
      '<h1>A little space.<br>For the things you need.</h1><p>Choose what belongs in your island. Everything else stays out of your way.</p><div class="feature-list"></div>';
    for (const group of groups) {
      const button = document.createElement("button");
      button.className = "feature-choice";
      button.dataset.feature = group.id;
      button.setAttribute("aria-pressed", choice.includes(group.id));
      button.innerHTML = `<span class="feature-icon">${icon(group.icon)}</span><span><strong>${group.title}</strong><span class="small">${group.detail}</span></span><span class="check">${choice.includes(group.id) ? icon("check") : ""}</span>`;
      button.onclick = () => {
        choice = choice.includes(group.id)
          ? choice.filter((id) => id !== group.id)
          : [...choice, group.id];
        renderPage();
      };
      section.querySelector(".feature-list").append(button);
    }
  } else if (step === 1) {
    section.innerHTML =
      '<h1>No notch. Same feeling.</h1><p>A floating island is made for your PC. Or bring the original shape to the edge of your screen.</p><div class="placements"></div>';
    for (const [value, title] of [
      ["floating", "Floating island"],
      ["edge", "Original edge"],
      ["corner", "Quiet corner"],
    ]) {
      const button = document.createElement("button");
      button.className = "placement " + value;
      button.dataset.placement = value;
      button.setAttribute("aria-pressed", layout === value);
      button.innerHTML = `<div class="diagram" aria-hidden="true"></div><strong>${title}</strong>`;
      button.onclick = () => {
        layout = value;
        void run("settings", { placement: layout });
        renderPage();
      };
      section.querySelector(".placements").append(button);
    }
    section.append(
      settingRow(
        "Glass surface",
        "Dark, translucent material with an opaque fallback",
        "glass",
      ),
    );
  } else {
    section.innerHTML = `<h1>Ready when you are.</h1><p>Rest your pointer on the island to open it. Move away and it quietly folds back.</p><div class="privacy-list"><div class="privacy-item">${icon("shield")}<p>Files, calendar imports and usage logs stay on this PC.</p></div><div class="privacy-item">${icon("camera")}<p>Camera and audio visualization start only when you choose them. Nothing is recorded.</p></div><div class="privacy-item">${icon("music")}<p>Lyrics lookup sends track metadata only when you ask. Account refresh uses your existing Codex CLI sign-in.</p></div></div>`;
    section.append(settingRow("Launch when I sign in", "", "startAtLogin"));
    const hint = document.createElement("p");
    hint.className = "shortcut";
    hint.innerHTML =
      "<kbd>Ctrl</kbd><kbd>Windows</kbd><kbd>B</kbd> brings it back.";
    section.append(hint);
  }
  const footer = document.createElement("footer");
  if (step) {
    const back = document.createElement("button");
    back.className = "action";
    back.innerHTML = icon("back") + "Back";
    back.onclick = () => {
      step--;
      renderPage();
    };
    footer.append(back);
  } else {
    const dots = document.createElement("div");
    dots.className = "step-dots";
    dots.innerHTML = [0, 1, 2]
      .map((i) => `<i class="${step === i ? "active" : ""}"></i>`)
      .join("");
    footer.append(dots);
  }
  const next = document.createElement("button");
  next.id = "onboarding-next";
  next.className = "action primary";
  next.innerHTML = (step === 2 ? "Open my island" : "Continue") + icon("arrow");
  next.onclick = async () => {
    if (step < 2) {
      step++;
      renderPage();
    } else {
      const saved = await run(
        "settings",
        { onboarded: true, features: choice, placement: layout },
        next,
      );
      if (saved) {
        model.settings = saved;
        wizard = false;
        page = firstPage();
        expand();
      }
    }
  };
  footer.append(next);
  section.append(footer);
  content.append(section);
}
function settingRow(title, description, key) {
  const row = document.createElement("label");
  row.className = "row";
  row.innerHTML = `<span>${e(title)}${description ? `<div class="description">${e(description)}</div>` : ""}</span>`;
  const input = document.createElement("input");
  input.type = "checkbox";
  input.className = "switch";
  input.checked = !!model.settings?.[key];
  input.id = `setting-${key}`;
  input.onchange = () => run("settings", { [key]: input.checked });
  row.append(input);
  return row;
}
function renderMusic() {
  $("#content").innerHTML =
    `<div class="music"><div class="track" id="track"></div><div class="artist" id="artist"></div><div class="lyric" id="lyric"></div><div class="backing" id="backing"></div><div class="spectrum" id="spectrum" hidden>${"<i></i>".repeat(20)}</div><div class="timeline"><input type="range" id="seek" aria-label="Playback position" min="0" max="1" step="0.1"><div class="time-labels"><span id="elapsed">0:00</span><span id="total">0:00</span></div></div><div class="transport"><button class="quiet" id="volume-button" aria-label="Sound output" title="Windows sound output">${icon("volume")}</button><button id="previous" aria-label="Previous track" title="Previous track">${icon("previous")}</button><button id="play" class="play" aria-label="Play">${icon("play")}</button><button id="next" aria-label="Next track" title="Next track">${icon("next")}</button><button class="quiet" disabled title="Manage favorites in your music player" aria-label="Favorites are managed in your player">${icon("heart")}</button></div></div>`;
  $("#previous").onclick = () => run("media", { action: "previous" });
  $("#next").onclick = () => run("media", { action: "next" });
  $("#play").onclick = () =>
    run("media", { action: model.media.playing ? "pause" : "play" });
  $("#volume-button").onclick = () =>
    run("windows-settings", { page: "sound" });
  $("#seek").onchange = (event) =>
    run("media", { action: "seek", position: Number(event.target.value) });
  $("#spectrum").hidden = !model.settings.visualizer;
  updateMedia();
  updatePlayback();
}
function updateMedia() {
  updateCompact();
  if (!expanded || wizard || page !== "music" || !$("#track")) return;
  const changed = $("#track").textContent !== model.media.title;
  $("#track").textContent = model.media.title || "Nothing playing yet";
  $("#artist").textContent =
    model.media.artist || "Play music in your favorite app";
  if (changed && !reduced())
    $(".track").animate(
      [
        { opacity: 0.25, transform: "translateY(2px)" },
        { opacity: 1, transform: "translateY(0)" },
      ],
      { duration: 160, easing: "ease-out" },
    );
  $("#play").innerHTML = icon(model.media.playing ? "pause" : "play");
  $("#play").setAttribute("aria-label", model.media.playing ? "Pause" : "Play");
  $("#play").title = model.media.playing ? "Pause" : "Play";
  const enabled =
    model.media.title &&
    model.media.title !== "Nothing playing yet" &&
    (model.media.musicSource !== "octave" || model.media.connected);
  for (const id of ["previous", "play", "next", "seek"])
    $("#" + id).disabled = !enabled;
  $(".music").classList.toggle("empty-music", !enabled);
  $("#seek").max = Math.max(1, model.media.duration || 0);
  updatePlayback();
  ensureFrame();
}
function updatePlayback() {
  if (!$("#seek")) return;
  const position = playbackPosition(model.media, Date.now());
  if (document.activeElement !== $("#seek")) $("#seek").value = position;
  $("#seek").style.setProperty(
    "--seek",
    `${Math.min(100, (position / Math.max(1, model.media.duration || 0)) * 100)}%`,
  );
  $("#elapsed").textContent = clock(Math.floor(position)).replace(/^0/, "");
  $("#total").textContent = clock(
    Math.floor(model.media.duration || 0),
  ).replace(/^0/, "");
  const line = currentLine(model.lyrics.lines, position);
  const lyric = $("#lyric");
  if (line !== lastLine) {
    lastLine = line;
    lyric.replaceChildren();
    if (line?.words?.length)
      for (const word of line.words) {
        const span = document.createElement("span");
        span.className = "word";
        span.textContent = word.text + " ";
        lyric.append(span);
      }
    else
      lyric.textContent =
        line?.text ||
        model.lyrics.plain ||
        (model.media.title === "Nothing playing yet"
          ? "Windows players · or Octave in Brave"
          : model.media.connected
            ? "Lyrics appear when Octave supplies them."
            : "Synchronized lyrics appear here.");
    if (!reduced())
      lyric.animate(
        [
          { opacity: 0.3, transform: "translateY(2px)" },
          { opacity: 1, transform: "translateY(0)" },
        ],
        { duration: 140, easing: "ease-out" },
      );
  }
  if (line?.words?.length)
    [...lyric.children].forEach((span, index) => {
      const word = line.words[index],
        active = position >= word.start && position <= word.end,
        progress =
          (position - word.start) / Math.max(0.001, word.end - word.start);
      span.className =
        "word" + (position > word.end ? " done" : active ? " singing" : "");
      if (active)
        span.style.backgroundImage = reduced()
          ? "linear-gradient(#fff,#fff)"
          : `linear-gradient(110deg,#cacacf ${progress * 100 - 28}%,#fff ${progress * 100}%,#bdbdc5 ${progress * 100 + 28}%)`;
      else span.style.backgroundImage = "";
    });
  const backing = currentLine(model.lyrics.lines, position, true);
  if (backing !== lastBackground) {
    lastBackground = backing;
    $("#backing").textContent = backing?.text || "";
  }
}
function renderFocus() {
  const caffeine = focusTab === "caffeine",
    minutes = caffeine ? caffeineDuration : duration;
  $("#content").innerHTML =
    `<div class="${caffeine ? "caffeine" : ""}"><div class="focus-tabs"><div class="segmented ${caffeine ? "amber" : ""}"><button id="timer-tab" class="${!caffeine ? "selected" : ""}">Timer</button><button id="caffeine-tab" class="${caffeine ? "selected" : ""}">Caffeine</button></div></div><div class="ruler" style="--marker:${((minutes - 5) / 55) * 100}%"><div class="ruler-ticks">${Array.from({ length: 56 }, (_, i) => `<i class="ruler-tick ${i % 5 === 0 ? "major" : ""}">${i % 5 === 0 ? `<label>${i + 5}</label>` : ""}</i>`).join("")}</div><div class="ruler-marker"></div><input id="duration" class="ruler-input" aria-label="${caffeine ? "Stay-awake" : "Focus"} duration in minutes" type="range" min="5" max="60" step="1" value="${minutes}"></div><div class="focus-footer"><div class="actions"><button id="focus-action" class="action">${icon(caffeine ? "coffee" : "play")}<span></span></button><button class="mini-reset" id="focus-reset">Reset</button></div><div class="focus-clock" id="focus-clock"></div></div><div class="focus-footnote"><label class="small">${caffeine ? "Keep Windows awake until the countdown ends." : `<input type="checkbox" id="focus-awake" ${model.focus.awake ? "checked" : ""}> Keep my PC awake during focus`}</label></div></div>`;
  $("#timer-tab").onclick = () => {
    focusTab = "timer";
    renderPage();
  };
  $("#caffeine-tab").onclick = () => {
    focusTab = "caffeine";
    renderPage();
  };
  $("#duration").oninput = (event) => {
    const value = Number(event.target.value);
    if (caffeine) caffeineDuration = value;
    else duration = value;
    $(".ruler").style.setProperty("--marker", `${((value - 5) / 55) * 100}%`);
    updateFocus();
  };
  $("#focus-action").onclick = () =>
    caffeine
      ? run("caffeine", {
          enabled: !model.focus.caffeineSeconds,
          minutes: caffeineDuration,
        })
      : run("focus", {
          action: model.focus.running
            ? "pause"
            : model.focus.paused
              ? "resume"
              : "start",
          minutes: duration,
          awake: $("#focus-awake").checked,
        });
  $("#focus-reset").onclick = () =>
    caffeine
      ? run("caffeine", { enabled: false })
      : run("focus", { action: "reset" });
  if ($("#focus-awake"))
    $("#focus-awake").onchange = (event) =>
      run("focus", { action: "awake", awake: event.target.checked });
  updateFocus();
}
function updateFocus() {
  updateHeader();
  updateCompact();
  if (page !== "focus" || !$("#focus-clock")) return;
  const caffeine = focusTab === "caffeine";
  $("#focus-clock").textContent = clock(
    caffeine
      ? model.focus.caffeineSeconds || caffeineDuration * 60
      : model.focus.running || model.focus.paused
        ? model.focus.seconds
        : duration * 60,
  );
  $("#focus-action span").textContent = caffeine
    ? model.focus.caffeineSeconds > 0
      ? "Stop keeping awake"
      : "Keep awake"
    : model.focus.running
      ? "Pause"
      : model.focus.paused
        ? "Resume"
        : "Start focus";
}
function renderFiles() {
  selected = new Set(
    [...selected].filter((path) =>
      model.shelf.some((item) => item.path === path),
    ),
  );
  $("#content").innerHTML =
    `<div class="section-top"><h2>Your shelf</h2><div class="actions"><button id="add-files" class="action">${icon("folder")}Add files</button><button id="capture" class="icon-button" title="Capture screen" aria-label="Capture screen">${icon("camera")}</button></div></div><div class="dropzone" id="dropzone">${icon("shelf")}<div><strong>Drop it here. Keep it handy.</strong><p>Copies on your shelf. Originals stay where they are.</p></div></div><div class="file-list" id="file-list"></div><div class="shelf-tools"><button id="zip-files" class="action">ZIP</button><button id="pdf-files" class="action">Make / merge PDF</button><select class="field" id="image-format" aria-label="Image format"><option value="jpg">Smaller JPEG</option><option value="png">PNG</option><option value="webp">WebP</option></select><button id="convert-files" class="action">Convert</button><button id="save-files" class="icon-button" title="Save copies" aria-label="Save copies">${icon("download")}</button><button id="share-files" class="icon-button" title="Windows / Nearby Sharing" aria-label="Share selected files">${icon("share")}</button></div><p class="file-note">Select files to use a tool. Drag a file row into another app.</p>`;
  for (const item of model.shelf) {
    const row = document.createElement("div");
    row.className = "file-row";
    row.draggable = true;
    row.innerHTML = `<label><input type="checkbox" ${selected.has(item.path) ? "checked" : ""}>${icon("file", "file-type")}<span title="${e(item.name)}">${e(item.name)}</span></label><button class="icon-button reveal" title="Show in folder" aria-label="Show ${e(item.name)} in folder">${icon("folder")}</button><button class="icon-button remove" title="Remove shelf copy" aria-label="Remove ${e(item.name)}">${icon("close")}</button>`;
    row.querySelector("input").onchange = (event) => {
      if (event.target.checked) selected.add(item.path);
      else selected.delete(item.path);
      updateSelection();
    };
    row.querySelector(".reveal").onclick = () =>
      run("reveal-file", { path: item.path });
    row.querySelector(".remove").onclick = () =>
      run("shelf-remove", { paths: [item.path] });
    row.ondblclick = () => run("open-file", { path: item.path });
    row.ondragstart = (event) => {
      event.preventDefault();
      window.island.dragFile(item.path);
    };
    $("#file-list").append(row);
  }
  $("#add-files").onclick = () => run("add-files", {}, $("#add-files"));
  $("#capture").onclick = () => run("screenshot", {}, $("#capture"));
  $("#zip-files").onclick = () =>
    run("zip", { paths: [...selected] }, $("#zip-files"));
  $("#pdf-files").onclick = () =>
    run("pdf", { paths: [...selected] }, $("#pdf-files"));
  $("#convert-files").onclick = () =>
    run(
      "image",
      {
        paths: [...selected],
        format: $("#image-format").value,
        width: $("#image-format").value === "jpg" ? 1920 : 0,
      },
      $("#convert-files"),
    );
  $("#save-files").onclick = () => run("save-copies", { paths: [...selected] });
  $("#share-files").onclick = () => run("share", { paths: [...selected] });
  updateSelection();
}
function updateSelection() {
  for (const id of [
    "zip-files",
    "pdf-files",
    "convert-files",
    "save-files",
    "share-files",
  ])
    if ($("#" + id)) $("#" + id).disabled = selected.size === 0;
}
function renderCalendar() {
  $("#content").innerHTML =
    `<div class="section-top"><h2>Your next two weeks</h2><button id="import-calendar" class="action">Import .ics</button></div><div class="scroll" style="max-height:${Math.min(375, model.viewport.height - 14) - 116}px"><div id="calendar-events" class="loading">Reading local calendars…</div><div class="divider"></div><h2>Reminders</h2><div class="reminder-entry"><input id="reminder-text" class="field" placeholder="A reminder for later…" aria-label="Reminder"><input id="reminder-minutes" class="field" type="number" min="1" max="10080" value="30" aria-label="Minutes until reminder"><button id="add-reminder" class="action">Add</button></div><div id="reminder-list"></div></div>`;
  $("#import-calendar").onclick = async () => {
    const value = await run("import-calendar");
    if (value && page === "calendar") drawCalendar(value);
  };
  $("#add-reminder").onclick = async () => {
    if ($("#reminder-text").value.trim()) {
      await run("reminder-add", {
        text: $("#reminder-text").value,
        minutes: Number($("#reminder-minutes").value),
      });
      if (page === "calendar") {
        $("#reminder-text").value = "";
        drawReminders();
      }
    }
  };
  void run("calendar").then((value) => {
    if (value && page === "calendar") drawCalendar(value);
  });
  drawReminders();
}
function drawCalendar(value) {
  const list = $("#calendar-events");
  if (!list) return;
  list.className = "";
  list.replaceChildren();
  for (const event of value.events) {
    const date = new Date(event.start);
    const row = document.createElement("div");
    row.className = "calendar-item";
    row.innerHTML = `<div class="calendar-date"><small>${e(date.toLocaleDateString(undefined, { month: "short" }))}</small>${date.getDate()}</div><div><strong>${e(event.title)}</strong><p>${e(date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }))}${event.location ? " · " + e(event.location) : ""}</p></div>`;
    list.append(row);
  }
  if (!value.events.length) {
    const note = document.createElement("p");
    note.className = "small";
    note.textContent =
      "Import an ICS export from Outlook, Google Calendar or your calendar app. Events and recurring dates are read locally.";
    list.append(note);
  }
  for (const file of value.files) {
    const button = action(
      "Remove " + file.split(/[\\/]/).at(-1),
      "calendar-remove",
      { path: file },
    );
    button.onclick = async () => {
      const result = await run("calendar-remove", { path: file });
      if (result && page === "calendar") drawCalendar(result);
    };
    list.append(button);
  }
  if (value.errors.length) showNotice(value.errors.join(" · "));
}
function drawReminders() {
  const list = $("#reminder-list");
  if (!list) return;
  list.replaceChildren();
  for (const reminder of model.settings.reminders || []) {
    const row = document.createElement("label");
    row.className = "row reminder-row" + (reminder.done ? " done" : "");
    row.innerHTML = `<input type="checkbox" ${reminder.done ? "checked" : ""}><span>${e(reminder.text)}</span><span class="small">${e(new Date(reminder.due).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }))}</span>`;
    row.querySelector("input").onchange = (event) =>
      run("reminder-done", { id: reminder.id, done: event.target.checked });
    list.append(row);
  }
}
function quotaRow(name, used, detail = "") {
  const left = Number.isFinite(used) ? Math.max(0, 100 - used) : null;
  return `<div class="quota-row"><div class="quota-name"><strong>${e(name)}</strong><p>${e(detail || (left === null ? "Refresh to see allowance" : "Last recorded allowance"))}</p></div><div class="quota-meter" role="meter" aria-label="${e(name)} remaining" ${left === null ? "" : `aria-valuemin="0" aria-valuemax="100" aria-valuenow="${left}"`}>${Array.from({ length: 24 }, (_, i) => `<i class="${left !== null && i < Math.round((left / 100) * 24) ? "full" : ""}"></i>`).join("")}</div><div class="quota-value">${left === null ? "—" : Math.round(left) + "%"}<small>left</small></div></div>`;
}
function renderCodex() {
  $("#content").innerHTML =
    `<div class="section-top"><div class="actions"><h2>Codex</h2><span class="small" id="codex-plan">Local sessions</span></div><button id="usage-refresh" class="icon-button" title="Refresh local logs" aria-label="Refresh local logs">${icon("refresh")}</button></div><div id="quota-rows">${quotaRow("5-hour", null)}${quotaRow("Weekly", null)}</div><div class="divider"></div><div id="usage" class="loading">Reading local usage…</div><div class="actions" style="margin-top:14px"><button id="live-quota" class="action">Refresh plan allowance</button><span class="small">Uses existing Codex CLI sign-in</span></div>`;
  const refresh = async () => {
    const data = await run("usage", {}, $("#usage-refresh"));
    if (data && page === "codex") {
      $("#quota-rows").innerHTML =
        quotaRow("5-hour", data.primaryUsed) +
        quotaRow("Weekly", data.secondaryUsed);
      $("#usage").className = "";
      $("#usage").innerHTML =
        `<div class="usage-total"><strong>${shortNumber(data.input + data.output)}</strong><span>tokens · ${data.sessions} sessions</span></div><p class="usage-details">${shortNumber(data.input)} input · ${shortNumber(data.cached)} cached · ${shortNumber(data.output)} output<br>Local session totals. Updated just now.</p>`;
      targetSize();
      if (data.unreadable)
        showNotice(`${data.unreadable} log files could not be read.`);
    }
  };
  $("#usage-refresh").onclick = refresh;
  void refresh();
  $("#live-quota").onclick = async () => {
    const data = await run("quota", {}, $("#live-quota"));
    if (data && page === "codex") {
      $("#codex-plan").textContent = data.plan;
      $("#quota-rows").innerHTML = data.windows
        .map((value) =>
          quotaRow(
            value.name,
            value.used,
            value.reset
              ? "Resets " + new Date(value.reset).toLocaleString()
              : "",
          ),
        )
        .join("");
      targetSize();
    }
  };
}
function renderSystem() {
  $("#content").innerHTML =
    `<div class="section-top"><h2>Your PC</h2><span class="small" id="system-power">${e(model.battery)}</span></div>${!model.windows ? '<p class="native-note">Windows controls are unavailable on this development host.</p>' : ""}<div class="system-level">${icon("volume")}<input id="system-volume" type="range" min="0" max="100" value="0" aria-label="Output volume"><button class="action" id="mute">Mute</button></div><div class="system-level">${icon("sun")}<input id="brightness" type="range" min="0" max="100" value="70" aria-label="Laptop brightness"><span class="small">Laptop display</span></div><div class="divider"></div><div class="actions"><button id="mirror" class="action">${icon("camera")}Mirror</button><button id="sound-settings" class="action">Sound settings</button><button id="camera-privacy" class="action">Camera privacy</button></div><p class="small" style="margin-top:10px">Mirror is preview only. External monitors may use their own brightness controls.</p>`;
  $("#system-volume").onchange = (event) =>
    run("volume", { value: Number(event.target.value) / 100 });
  $("#brightness").onchange = (event) =>
    run("brightness", { value: Number(event.target.value) });
  $("#mute").onclick = () => run("mute");
  $("#mirror").onclick = () => go("mirror");
  $("#sound-settings").onclick = () =>
    run("windows-settings", { page: "sound" });
  $("#camera-privacy").onclick = () =>
    run("windows-settings", { page: "camera" });
  void run("system").then((data) => {
    if (data && page === "system") {
      $("#system-volume").value = data.volume * 100;
      $("#system-power").textContent = data.battery;
    }
  });
}
function renderMirror() {
  $("#content").innerHTML =
    `<div class="section-top"><h2>Mirror</h2><button id="close-camera" class="action">Close camera</button></div><div class="mirror-preview"><img id="camera-image" alt="Live mirrored camera preview"><p>${model.windows ? "Opening camera…" : "Camera preview requires Windows."}</p></div><p class="small">Preview only. No microphone, recording or upload.</p>`;
  $("#close-camera").onclick = () => go("system");
  void run("view", { expanded: true, page: "mirror" }).then(() =>
    run("mirror"),
  );
}
function renderSettings() {
  $("#content").innerHTML =
    `<div class="section-top"><h2>Make it yours</h2><div class="segmented"><button id="general-settings" class="${settingsTab === "general" ? "selected" : ""}">General</button><button id="music-settings" class="${settingsTab === "music" ? "selected" : ""}">Music</button><button id="system-settings" class="${settingsTab === "system" ? "selected" : ""}">System</button></div></div><div class="scroll settings-page" id="settings-body" style="max-height:${Math.min(settingsTab === "general" ? 540 : settingsTab === "system" ? 405 : 310, model.viewport.height - 14) - 116}px"></div>`;
  for (const value of ["general", "music", "system"])
    $("#" + value + "-settings").onclick = () => {
      settingsTab = value;
      renderPage();
    };
  const body = $("#settings-body");
  if (settingsTab === "general") {
    for (const group of groups) {
      const label = document.createElement("label");
      label.className = "row";
      label.innerHTML = `<span>${group.title}</span><input type="checkbox" class="switch" ${model.settings.features.includes(group.id) ? "checked" : ""}>`;
      label.querySelector("input").onchange = (event) =>
        run("settings", {
          features: event.target.checked
            ? [...model.settings.features, group.id]
            : model.settings.features.filter((id) => id !== group.id),
        });
      body.append(label);
    }
    const title = document.createElement("h2");
    title.textContent = "Placement";
    body.append(title);
    const choices = document.createElement("div");
    choices.className = "segmented";
    for (const [value, label] of [
      ["floating", "Floating"],
      ["edge", "Original edge"],
      ["corner", "Corner"],
    ]) {
      const button = document.createElement("button");
      button.textContent = label;
      button.className = model.settings.placement === value ? "selected" : "";
      button.onclick = () => run("settings", { placement: value });
      choices.append(button);
    }
    body.append(choices);
    const displayRow = document.createElement("label");
    displayRow.className = "row";
    displayRow.innerHTML =
      '<span>Display</span><select class="field" aria-label="Display"></select>';
    for (const display of model.viewport.displays || []) {
      const option = document.createElement("option");
      option.value = display.index;
      option.textContent = `Display ${display.index + 1} · ${display.width} × ${display.height}`;
      displayRow.querySelector("select").append(option);
    }
    displayRow.querySelector("select").value = model.settings.monitor;
    displayRow.querySelector("select").onchange = (event) =>
      run("settings", { monitor: Number(event.target.value) });
    body.append(displayRow);
    for (const [key, label] of [
      ["glass", "Glass surface"],
      ["reducedMotion", "Reduced motion"],
      ["hoverOpen", "Open when the pointer rests here"],
      ["autoCollapse", "Collapse when the pointer leaves"],
      ["hideInFullscreen", "Hide during fullscreen apps"],
      ["startAtLogin", "Start at sign-in"],
    ])
      body.append(settingRow(label, "", key));
    const footer = document.createElement("div");
    footer.className = "settings-footer";
    footer.innerHTML =
      "<p>Boring Notch Octave · Windows<br>GPL-3.0 · TheBoredTeam / Vedanth Jadhav</p>";
    const replay = document.createElement("button");
    replay.className = "action";
    replay.textContent = "Run onboarding again";
    replay.onclick = () => {
      wizard = true;
      step = 0;
      choice = [...model.settings.features];
      layout = model.settings.placement;
      renderPage();
      void run("view", { expanded: true, page: "onboarding" });
    };
    footer.append(replay);
    body.append(footer);
  } else if (settingsTab === "music") {
    const source = document.createElement("label");
    source.className = "row";
    source.innerHTML =
      '<span>Music source</span><select class="field" id="music-source"><option value="system">Windows players</option><option value="octave">Octave in Brave</option></select>';
    source.querySelector("select").value = model.settings.musicSource;
    source.querySelector("select").onchange = (event) =>
      run("settings", { musicSource: event.target.value });
    body.append(source);
    body.append(settingRow("Romanize Hindi, Punjabi and Urdu", "", "romanize"));
    body.append(
      settingRow(
        "Audio visualization",
        "Processes speaker audio locally while music is open",
        "visualizer",
      ),
    );
    const note = document.createElement("p");
    note.className = "small";
    note.style.marginTop = "14px";
    note.textContent =
      "Octave: load the included extension in Brave. The Windows installer registers its connection. Exact word timing comes from the provider.";
    body.append(note);
    const lookup = action("Find lyrics · LRCLIB", "lyrics");
    lookup.style.marginTop = "12px";
    body.append(lookup);
    const privacy = document.createElement("p");
    privacy.className = "small";
    privacy.style.marginTop = "8px";
    privacy.textContent =
      "Lookup sends only track title, artist and duration to LRCLIB when clicked. Results are cached locally.";
    body.append(privacy);
  } else {
    const note = document.createElement("p");
    note.textContent =
      "Choose a Codex CLI folder for local session totals. Live plan refresh uses its existing sign-in only when clicked.";
    body.append(note);
    const label = document.createElement("label");
    label.className = "row";
    label.innerHTML =
      '<span>Codex folder</span><input class="field" id="codex-folder" aria-label="Codex folder">';
    label.querySelector("input").value = model.settings.codexHome;
    body.append(label);
    const save = document.createElement("button");
    save.className = "action";
    save.textContent = "Save folder";
    save.onclick = () =>
      run("settings", { codexHome: $("#codex-folder").value }, save);
    body.append(save);
    const divider = document.createElement("div");
    divider.className = "divider";
    body.append(divider);
    body.append(
      action("Windows sound settings", "windows-settings", { page: "sound" }),
    );
    body.append(
      action("Camera privacy", "windows-settings", { page: "camera" }),
    );
    const privacy = document.createElement("p");
    privacy.className = "small";
    privacy.style.marginTop = "14px";
    privacy.textContent =
      "Camera stops when the island collapses or you leave Mirror. Windows privacy settings control access. No personal files or session logs are uploaded.";
    body.append(privacy);
  }
  const actions = document.createElement("div");
  actions.className = "actions";
  actions.style.marginTop = "14px";
  actions.append(action("Hide island", "hide"), action("Quit", "quit"));
  body.append(actions);
}

window.island.on((name, data) => {
  if (name === "ready") {
    const wasReady = !!model.settings;
    model = { ...model, ...data };
    layout = model.settings.placement;
    choice = [...model.settings.features];
    if (!wasReady) {
      wizard = !model.settings.onboarded;
      page = firstPage();
      if (wizard) expand();
      else {
        updateCompact();
        targetSize();
        drawGeometry();
      }
    }
  } else if (name === "settings") {
    const scroll = $("#settings-body")?.scrollTop || 0;
    model.settings = data;
    layout = data.placement;
    renderTabs();
    if (expanded && (page === "settings" || (wizard && step > 0))) {
      renderPage();
      if ($("#settings-body")) $("#settings-body").scrollTop = scroll;
    }
    if (page === "calendar") drawReminders();
    targetSize();
    updateCompact();
  } else if (name === "media") {
    model.media = data;
    updateMedia();
  } else if (name === "lyrics") {
    model.lyrics = data;
    lastLine = undefined;
    if (expanded && page === "music") updatePlayback();
  } else if (name === "artwork") {
    model.artwork = data;
    if (data) {
      $("#cover").src = data;
      const image = new Image();
      image.onload = () => {
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 1;
        const context = canvas.getContext("2d", { willReadFrequently: true });
        context.drawImage(image, 0, 0, 1, 1);
        const rgb = [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
        const luminance = (colors) =>
          colors.reduce((sum, channel, i) => {
            const c = channel / 255;
            return (
              sum +
              [0.2126, 0.7152, 0.0722][i] *
                (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4)
            );
          }, 0);
        while (luminance(rgb) < 0.32)
          for (let i = 0; i < 3; i++) rgb[i] += (255 - rgb[i]) * 0.08;
        document.documentElement.style.setProperty(
          "--accent",
          `rgb(${rgb.map(Math.round).join(",")})`,
        );
      };
      image.src = data;
    } else {
      $("#cover").removeAttribute("src");
      document.documentElement.style.setProperty("--accent", "#70d8ef");
    }
  } else if (name === "focus") {
    model.focus = data;
    updateFocus();
    if (expanded && page === "music" && reduced()) updatePlayback();
  } else if (name === "shelf") {
    model.shelf = data;
    if (expanded && page === "files") {
      renderFiles();
      targetSize();
    }
  } else if (name === "battery") {
    model.battery = data;
    updateHeader();
    if ($("#system-power")) $("#system-power").textContent = data;
  } else if (name === "volume") {
    if ($("#system-volume")) $("#system-volume").value = data.volume * 100;
    osd = data.muted
      ? "Output muted"
      : `Volume · ${Math.round(data.volume * 100)}%`;
    updateCompact();
    clearTimeout(osdTimeout);
    osdTimeout = setTimeout(() => {
      osd = "";
      updateCompact();
    }, 1600);
  } else if (name === "audio") {
    for (const [index, bar] of [
      ...document.querySelectorAll("#spectrum i"),
    ].entries())
      bar.style.transform = `scaleY(${0.13 + Math.min(1, (data[index] || 0) * 3) * 0.87})`;
  } else if (name === "camera" && $("#camera-image"))
    $("#camera-image").src = data;
  else if (name === "pointer") pointerChanged(data);
  else if (name === "visibility") {
    visible = data;
    if (!data) {
      clearTimeout(hoverTimeout);
      clearTimeout(closeTimeout);
      if (!wizard) collapse();
    } else ensureFrame();
    updateCompact();
  } else if (name === "open") expand(typeof data === "string" ? data : null);
  else if (name === "viewport") {
    model.viewport = data;
    targetSize();
  } else if (name === "material") {
    model.material = data;
    drawGeometry();
  } else if (name === "notice") showNotice(data);
});

$("#cover-fallback").innerHTML = icon("music");
$("#compact").onclick = () => expand();
$("#compact").onkeydown = (event) => {
  if (["Enter", " "].includes(event.key)) {
    event.preventDefault();
    expand();
  }
};
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (wizard && model.settings?.onboarded) {
      wizard = false;
      go("settings");
    } else if (wizard) void run("hide");
    else collapse();
  }
  if (
    event.code === "Space" &&
    !["INPUT", "SELECT", "TEXTAREA", "BUTTON"].includes(
      document.activeElement.tagName,
    ) &&
    expanded &&
    page === "music" &&
    !wizard
  ) {
    event.preventDefault();
    void run("media", { action: model.media.playing ? "pause" : "play" });
  }
});
document.addEventListener("dragover", (event) => {
  if (!allowed("files")) return;
  event.preventDefault();
  if (!expanded || page !== "files") go("files");
  $("#dropzone")?.classList.add("dragging");
});
document.addEventListener("dragleave", () =>
  $("#dropzone")?.classList.remove("dragging"),
);
document.addEventListener("drop", (event) => {
  if (!allowed("files")) return;
  event.preventDefault();
  const paths = [...event.dataTransfer.files]
    .map((file) => window.island.filePath(file))
    .filter(Boolean);
  if (paths.length) void run("shelf-add", { paths });
  $("#dropzone")?.classList.remove("dragging");
});
motionPreference.addEventListener("change", targetSize);
window.addEventListener("resize", () => {
  model.viewport = {
    ...model.viewport,
    width: innerWidth,
    height: innerHeight,
  };
  if (expanded && page === "settings") renderPage();
  else targetSize();
});
const snapshot = await window.island.snapshot();
model = { ...model, ...snapshot };
if (model.settings) {
  layout = model.settings.placement;
  choice = [...model.settings.features];
  wizard = !model.settings.onboarded;
  page = firstPage();
  if (wizard) expand();
}
updateCompact();
targetSize();
drawGeometry();
if (model.artwork) $("#cover").src = model.artwork;
