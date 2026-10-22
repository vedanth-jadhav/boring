"use strict";

const hostName = "com.boringnotch.local.octave";
let nativePort = null;
let activeTab = null;
let reconnectTimer = null;
let reconnectDelay = 250;
let idleTimer = null;
let superseded = false;
const lastState = new Map();
const lastLyrics = new Map();
const currentDocuments = new Map();
let activityOrder = 0;
const lastReceived = new Map();
const refreshingTabs = new Map();
let pendingProbe = null;
let probeSequence = 0;
const recoveryAlarm = "octave-bridge-recovery";

function withDeadline(promise) {
  let timeout;
  return Promise.race([promise, new Promise((_, reject) => {
    timeout = setTimeout(() => reject(new Error("Octave tab did not respond")), 3000);
  })]).finally(() => clearTimeout(timeout));
}

function sameTrack(a, b) {
  return a && b && a.title === b.title && a.artist === b.artist &&
    (!a.trackID || !b.trackID || a.trackID === b.trackID);
}

function publishCachedLyrics(tabId) {
  const lyrics = lastLyrics.get(tabId);
  const state = lastState.get(tabId);
  if (sameTrack(lyrics, state) && lyrics.documentId === state.documentId) {
    sendNative(lyrics);
  }
}

function scheduleReconnect() {
  if (reconnectTimer !== null || activeTab === null || superseded) return;
  reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, reconnectDelay);
  reconnectDelay = Math.min(5000, reconnectDelay * 2);
}

function sendNative(message) {
  const {documentId: _documentId, activityOrder: _activityOrder, ...payload} = message;
  try { nativePort?.postMessage(payload); }
  catch (_) {
    const port = nativePort;
    nativePort = null;
    pendingProbe = null;
    port?.disconnect();
    scheduleReconnect();
  }
}

function refreshTab(tabId) {
  if (refreshingTabs.has(tabId)) return refreshingTabs.get(tabId);
  const refresh = async () => {
    try {
      const reply = await withDeadline(chrome.tabs.sendMessage(tabId, {type: "command", action: "refresh"}));
      if (reply?.accepted === true) return;
    } catch (_) {}
    try {
      // Extension reloads invalidate old content contexts in already-open tabs.
      // Both files are idempotent; repair listeners without reloading the music.
      await withDeadline(chrome.scripting.executeScript({target: {tabId}, world: "MAIN", files: ["page.js"]}));
      await withDeadline(chrome.scripting.executeScript({target: {tabId}, files: ["content.js"]}));
      await withDeadline(chrome.tabs.sendMessage(tabId, {type: "command", action: "refresh"}));
    } catch (error) {
      // Navigation/discard may remove the document midway; the next alarm retries.
      console.warn("Octave tab recovery deferred:", tabId, String(error));
    }
  };
  const task = refresh().finally(() => refreshingTabs.delete(tabId));
  refreshingTabs.set(tabId, task);
  return task;
}

function recoverTabs() {
  return chrome.tabs.query({url: "https://music.octavestreaming.com/*"})
    .then(tabs => Promise.all(tabs.filter(tab => !tab.discarded).map(tab => refreshTab(tab.id)))).catch(() => {});
}

function checkBridge() {
  if (activeTab === null || superseded) return;
  const now = Date.now();
  if (nativePort && pendingProbe && now - pendingProbe.sentAt >= 10000) {
    console.warn("Octave native bridge stopped responding; reconnecting");
    const port = nativePort;
    nativePort = null;
    pendingProbe = null;
    port.disconnect();
    scheduleReconnect();
  } else if (nativePort && !pendingProbe) {
    pendingProbe = {nonce: String(++probeSequence), sentAt: now};
    sendNative({type: "ping", nonce: pendingProbe.nonce});
  } else if (!nativePort) connect();
  if (now - (lastReceived.get(activeTab) ?? 0) >= 15000) refreshTab(activeTab);
}

function connect() {
  if (nativePort || superseded) return false;
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  try {
    const port = chrome.runtime.connectNative(hostName);
    nativePort = port;
    pendingProbe = null;
    port.onMessage.addListener(message => {
      if (nativePort === port && message?.type === "pong" && message.nonce === pendingProbe?.nonce) {
        pendingProbe = null;
        return;
      }
      if (nativePort === port && message?.type === "superseded") {
        superseded = true;
        nativePort = null;
        pendingProbe = null;
        port.disconnect();
        return;
      }
      if (nativePort !== port || message?.type !== "command" || activeTab === null) return;
      const tabId = activeTab;
      const state = lastState.get(tabId);
      withDeadline(chrome.tabs.sendMessage(tabId, message, state?.documentId ? {documentId: state.documentId} : undefined)).catch(() => {
        if (lastState.get(tabId) !== state) return;
        // A temporarily missing receiver is not evidence that playback ended.
        // Repair it without clearing the song or replaying a non-idempotent skip.
        refreshTab(tabId);
      });
    });
    port.onDisconnect.addListener(() => {
      const reason = chrome.runtime.lastError?.message;
      if (nativePort !== port) return;
      nativePort = null;
      pendingProbe = null;
      console.warn("Octave native bridge disconnected:", reason ?? "native host closed");
      scheduleReconnect();
    });
    if (activeTab !== null) {
      sendNative({type: "state", ...lastState.get(activeTab)});
      publishCachedLyrics(activeTab);
      // Cached anchors can be several seconds old after native reconnect.
      // Ask the media element for a fresh sample immediately.
      refreshTab(activeTab);
    }
    return activeTab !== null;
  } catch (error) {
    console.warn("Octave native bridge connection failed:", String(error));
    scheduleReconnect();
    return false;
  }
}

function selectTab() {
  let next = null;
  let best = null;
  for (const [tabId, state] of lastState) {
    if (state.title && (!best || Number(state.playing) > Number(best.playing) ||
        state.playing === best.playing && state.activityOrder > best.activityOrder)) {
      next = tabId;
      best = state;
    }
  }
  if (next === activeTab) return false;
  clearTimeout(idleTimer);
  activeTab = next;
  if (next === null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    // Let the explicit gone message drain, then release the idle Python host.
    idleTimer = setTimeout(() => {
      if (activeTab !== null) return;
      const port = nativePort;
      nativePort = null;
      port?.disconnect();
    }, 1000);
  }
  if (nativePort) {
    sendNative(next === null ? {type: "gone"} : {type: "state", ...lastState.get(next)});
    if (next !== null) publishCachedLyrics(next);
    return true;
  }
  return false;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {

  if (!sender.tab || sender.frameId != null && sender.frameId !== 0 ||
      !sender.tab.url?.startsWith("https://music.octavestreaming.com/")) return;
  if (!message || typeof message !== "object") return;
  if (sender.documentLifecycle && sender.documentLifecycle !== "active" ||
      sender.documentId && currentDocuments.has(sender.tab.id) && currentDocuments.get(sender.tab.id) !== sender.documentId) {
    sendResponse?.({accepted: true});
    return;
  }
  if (message.type === "state") {
    if (typeof message.title !== "string" || message.title.length > 4096 ||
        typeof message.artist !== "string" || message.artist.length > 4096 || typeof message.playing !== "boolean" ||
        !Number.isFinite(message.position) || !Number.isFinite(message.duration) ||
        message.artworks != null && (!Array.isArray(message.artworks) || message.artworks.length > 8 ||
          message.artworks.some(source => typeof source !== "string" || source.length > 150000)) ||
        JSON.stringify(message).length > 200000) return;
    if (sender.documentId) currentDocuments.set(sender.tab.id, sender.documentId);
    const previous = lastState.get(sender.tab.id);
    if (previous?.documentId === sender.documentId && Number.isFinite(message.sampledAt) &&
        Number.isFinite(previous?.sampledAt) && message.sampledAt <= previous.sampledAt) {
      sendResponse?.({accepted: true});
      return;
    }
    const activity = previous && previous.playing === message.playing && sameTrack(previous, message)
      ? previous.activityOrder : ++activityOrder;
    if (message.playing && (!previous?.playing || !sameTrack(previous, message))) superseded = false;
    lastState.set(sender.tab.id, {...message, documentId: sender.documentId, activityOrder: activity});
    lastReceived.set(sender.tab.id, Date.now());
    const published = selectTab();
    if (sender.tab.id === activeTab) {
      const replayed = connect();
      if (!published && !replayed) {
        sendNative(message);
        if (previous?.title !== message.title || previous?.artist !== message.artist) publishCachedLyrics(activeTab);
      }
      reconnectDelay = 250;
    }
  } else if (message.type === "lyrics") {
    if (typeof message.title !== "string" || typeof message.artist !== "string" ||
        !Array.isArray(message.lines) || JSON.stringify(message).length > 200000) return;
    lastLyrics.set(sender.tab.id, {...message, documentId: sender.documentId});
    const state = lastState.get(sender.tab.id);
    if (sender.tab.id === activeTab && state?.documentId === sender.documentId && sameTrack(state, message)) sendNative(message);
  } else if (message.type === "artwork") {
    const state = lastState.get(sender.tab.id);
    if (sender.tab.id !== activeTab || state?.documentId !== sender.documentId ||
        !state.artworks?.includes(message.url) || typeof message.requestID !== "string" ||
        typeof message.data !== "string" || message.data.length > 400000 || !/^[A-Za-z0-9+/]*={0,2}$/.test(message.data)) return;
    sendNative(message);
  } else return;
  sendResponse?.({accepted: true});
});
function clearTab(tabId) {
  lastState.delete(tabId); lastLyrics.delete(tabId); lastReceived.delete(tabId); selectTab();
}
chrome.tabs.onRemoved.addListener(tabId => { currentDocuments.delete(tabId); clearTab(tabId); });
chrome.webNavigation.onCommitted.addListener(({tabId, frameId, documentId, url}) => {
  if (frameId !== 0) return;
  const isOctave = url.startsWith("https://music.octavestreaming.com/");
  if (!isOctave && !currentDocuments.has(tabId) && !lastState.has(tabId)) return;
  // A loading status is not a new document: artist/history navigation and
  // aborted loads can leave the same audio engine alive. Only a committed
  // document change retires it. Tracking the current ID also rejects every
  // older document, while allowing an explicitly restored back/forward page.
  currentDocuments.set(tabId, documentId);
  if (!isOctave ||
      lastState.has(tabId) && lastState.get(tabId).documentId !== documentId) clearTab(tabId);
});
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  if (change.discarded === true) clearTab(tabId);
  if ((change.audible === true || change.status === "complete" || change.url) &&
      tab?.url?.startsWith("https://music.octavestreaming.com/")) refreshTab(tabId);
});
// A native port keeps this worker alive during playback. The alarm also wakes a
// terminated worker and rediscovers tabs whose content context stopped sending.
setInterval(checkBridge, 5000);
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name !== recoveryAlarm) return;
  checkBridge();
  recoverTabs();
});
chrome.alarms.get(recoveryAlarm).then(alarm => {
  if (!alarm) return chrome.alarms.create(recoveryAlarm, {periodInMinutes: 0.5});
}).catch(error => console.warn("Octave recovery alarm unavailable:", String(error)));
recoverTabs();
