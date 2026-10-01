"use strict";

window.addEventListener("message", event => {
  if (event.source !== window || event.origin !== "https://music.octavestreaming.com") return;
  const data = event.data;
  if (data?.source !== "boring-notch-octave" || !["state", "lyrics"].includes(data.type)) return;
  chrome.runtime.sendMessage(data).catch(() => {});
});

chrome.runtime.onMessage.addListener(message => {
  if (message.type === "command") {
    window.postMessage({source: "boring-notch-command", action: message.action,
      position: message.position, sequence: message.sequence, volume: message.volume}, location.origin);
  }
});
