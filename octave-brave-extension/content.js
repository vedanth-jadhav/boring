"use strict";

(() => {
  if (window.__boringNotchOctaveContent) return;
  window.__boringNotchOctaveContent = true;

  let pendingState = null;
  let pendingLyrics = null;
  let pendingArtwork = null;
  let sending = false;
  let retryTimer = null;
  let failures = 0;
  let invalidated = false;
  let refreshSequence = 0;
  const refreshReplies = new Map();

  async function flush() {
    if (!chrome.runtime.id) {
      invalidated = true;
      clearTimeout(retryTimer);
      retryTimer = null;
    }
    if (sending || invalidated || retryTimer !== null) return;
    const message = pendingState || pendingArtwork || pendingLyrics;
    if (!message) return;
    sending = true;
    let acknowledgementTimeout;
    try {
      const response = await Promise.race([
        chrome.runtime.sendMessage(message),
        new Promise((_, reject) => {
          acknowledgementTimeout = setTimeout(() => reject(new Error("Bridge acknowledgement timed out")), 3000);
        })
      ]);
      if (response?.accepted !== true) throw new Error("Bridge did not acknowledge state");
      if (pendingState === message) pendingState = null;
      if (pendingLyrics === message) pendingLyrics = null;
      if (pendingArtwork === message) pendingArtwork = null;
      failures = 0;
    } catch (_) {
      if (!chrome.runtime.id) invalidated = true;
      else retryTimer = setTimeout(() => {
        retryTimer = null;
        flush();
      }, Math.min(5000, 100 * 2 ** Math.min(failures++, 6)));
    } finally {
      clearTimeout(acknowledgementTimeout);
    }
    sending = false;
    if (retryTimer === null && !invalidated) flush();
  }

  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== "https://music.octavestreaming.com") return;
    const data = event.data;
    if (data?.source === "boring-notch-octave" && data.type === "ready") {
      refreshReplies.get(data.requestID)?.();
      return;
    }
    if (data?.source !== "boring-notch-octave" || !["state", "lyrics", "artwork"].includes(data.type)) return;
    if (data.type === "state") {
      pendingState = data;
      if (pendingLyrics && (pendingLyrics.title !== data.title || pendingLyrics.artist !== data.artist)) pendingLyrics = null;
      if (pendingArtwork && !data.artworks?.includes(pendingArtwork.url)) pendingArtwork = null;
    } else if (data.type === "artwork") pendingArtwork = data;
    else pendingLyrics = data;
    flush();
  });

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "command") {
      let requestID = message.requestID;
      if (message.action === "refresh") {
        requestID = `refresh-${++refreshSequence}`;
        const timeout = setTimeout(() => {
          refreshReplies.delete(requestID);
          sendResponse?.({accepted: false});
        }, 2000);
        refreshReplies.set(requestID, () => {
          clearTimeout(timeout);
          refreshReplies.delete(requestID);
          sendResponse?.({accepted: true});
        });
      }
      window.postMessage({source: "boring-notch-command", action: message.action,
        position: message.position, sequence: message.sequence, volume: message.volume, session: message.session,
        url: message.url, requestID}, location.origin);
      // Confirm the MAIN-world observer actually ran, not just this relay.
      if (message.action === "refresh") return true;
      sendResponse?.({accepted: true});
    }
  });

  // MAIN-world startup can precede this listener; recover its initial snapshot.
  window.postMessage({source: "boring-notch-command", action: "refresh"}, location.origin);
})();
