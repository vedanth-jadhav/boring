"use strict";

const hostName = "com.boringnotch.local.octave";
let nativePort = null;
let activeTab = null;
let reconnectTimer = null;
const lastState = new Map();
const lastLyrics = new Map();

function publishCachedLyrics(tabId) {
  const lyrics = lastLyrics.get(tabId);
  const state = lastState.get(tabId);
  if (lyrics && state && lyrics.title === state.title && lyrics.artist === state.artist) {
    nativePort?.postMessage(lyrics);
  }
}

function connect() {
  if (nativePort) return;
  try {
    const port = chrome.runtime.connectNative(hostName);
    nativePort = port;
    port.onMessage.addListener(message => {
      if (message.type !== "command" || activeTab === null) return;
      chrome.tabs.sendMessage(activeTab, message).catch(() => {
        activeTab = null;
        selectTab();
      });
    });
    port.onDisconnect.addListener(() => {
      if (nativePort !== port) return;
      nativePort = null;
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connect, 1500);
    });
    if (activeTab !== null) {
      port.postMessage({type: "state", ...lastState.get(activeTab)});
      publishCachedLyrics(activeTab);
      // Cached anchors can be several seconds old after native reconnect.
      // Ask the media element for a fresh sample immediately.
      chrome.tabs.sendMessage(activeTab, {type: "command", action: "refresh"}).catch(() => {});
    }
  } catch (_) {
    reconnectTimer = setTimeout(connect, 1500);
  }
}

function selectTab() {
  const entries = [...lastState.entries()].filter(([, state]) => state.title);
  entries.sort((a, b) => (b[1].playing - a[1].playing) || (b[1].observedAt - a[1].observedAt));
  const next = entries[0]?.[0] ?? null;
  if (next === activeTab) return;
  activeTab = next;
  if (nativePort) {
    nativePort.postMessage(next === null ? {type: "gone"} : {type: "state", ...lastState.get(next)});
    if (next !== null) publishCachedLyrics(next);
  }
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (!sender.tab || !sender.tab.url?.startsWith("https://music.octavestreaming.com/")) return;
  if (message.type === "state") {
    lastState.set(sender.tab.id, {...message, observedAt: Date.now()});
    selectTab();
    if (sender.tab.id === activeTab) {
      connect();
      nativePort?.postMessage(message);
    }
  } else if (message.type === "lyrics") {
    lastLyrics.set(sender.tab.id, message);
    if (sender.tab.id === activeTab) nativePort?.postMessage(message);
  }
});
chrome.tabs.onRemoved.addListener(tabId => { lastState.delete(tabId); lastLyrics.delete(tabId); selectTab(); });
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === "loading" || (change.url && !change.url.startsWith("https://music.octavestreaming.com/"))) {
    lastState.delete(tabId); lastLyrics.delete(tabId); selectTab();
  }
});
connect();
