"use strict";

(() => {
  if (window.__boringNotchOctaveBridge) return;
  window.__boringNotchOctaveBridge = true;
  const handlers = new Map();
  let deck = null;
  let lastSnapshot = "";
  let latestSeek = 0;
  let playerStore = null;
  let unsubscribePlayer = null;
  let lyricTrackID = null;
  let lyricRequest = null;
  const media = navigator.mediaSession;
  const originalHandler = media.setActionHandler.bind(media);
  media.setActionHandler = (action, handler) => {
    if (handler) handlers.set(action, handler);
    else handlers.delete(action);
    return originalHandler(action, handler);
  };

  function bindPlayerStore(store) {
    if (playerStore === store) return;
    unsubscribePlayer?.();
    playerStore = store;
    unsubscribePlayer = store?.subscribe?.((state, previous) => {
      if (state.currentTrack?.id !== previous.currentTrack?.id ||
          state.shuffle !== previous.shuffle || state.smartShuffle !== previous.smartShuffle) publish(true);
    });
    publish(true);
  }

  function parseLyrics(body) {
    if (body.richSync?.length) return body.richSync.map(line => ({
      time: line.start, end: line.end, text: line.text,
      ...(line.isBackground === true ? {isBackground: true} : {}),
      words: (line.words || []).map(word => ({start: word.start, end: word.end, text: word.word,
        ...(word.isBackground === true ? {isBackground: true} : {})}))
    }));
    if (!body.synced || !body.lyrics) return [];
    return body.lyrics.split(/\r?\n/).flatMap(line => {
      const stamps = [...line.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
      if (!stamps.length) return [];
      const content = line.slice(stamps.at(-1).index + stamps.at(-1)[0].length);
      const marks = [...content.matchAll(/<(\d+):(\d+(?:\.\d+)?)>/g)];
      const text = content.replace(/<\d+:\d+(?:\.\d+)?>/g, "").trim();
      const seconds = mark => Number(mark[1]) * 60 + Number(mark[2]);
      return stamps.map(stamp => {
        const shift = seconds(stamp) - seconds(stamps[0]);
        let words = marks.slice(0, -1).map((mark, i) => ({
          start: seconds(mark) + shift, end: seconds(marks[i + 1]) + shift,
          text: content.slice(mark.index + mark[0].length, marks[i + 1].index).trim()
        })).filter(word => word.text);
        if (words.map(word => word.text).join(" ") !== text) words = [];
        return {time: seconds(stamp), text, words};
      });
    });
  }

  async function requestLyrics(track) {
    if (!track?.id || track.id === lyricTrackID) return;
    lyricTrackID = track.id;
    lyricRequest?.abort();
    const request = new AbortController();
    lyricRequest = request;
    const title = track.title || "";
    const artist = track.artist?.name || "";
    try {
      const response = await fetch("https://api.octavestreaming.com/api/lyrics", {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({id: track.id, title, artist, album: track.album?.title || "",
          duration: track.duration || 0}), signal: request.signal});
      const body = await response.json();
      if (request.signal.aborted) return;
      window.postMessage({source: "boring-notch-octave", type: "lyrics", title, artist,
        lines: body.success ? parseLyrics(body) : [],
        plainLyrics: body.success && !body.synced && !body.richSync?.length ? body.lyrics || "" : ""}, location.origin);
    } catch (_) {
      if (!request.signal.aborted) window.postMessage({source: "boring-notch-octave", type: "lyrics",
        title, artist, lines: []}, location.origin);
    }
  }

  function publish(force = false) {
    const engine = window.__octaveEngine;
    const audio = engine?.active;
    if (audio !== deck) {
      if (deck) for (const name of events) deck.removeEventListener(name, publish);
      deck = audio || null;
      if (deck) for (const name of events) deck.addEventListener(name, publish);
    }
    const metadata = media.metadata;
    if (!audio || !metadata?.title) return;
    const player = playerStore?.getState?.();
    requestLyrics(player?.currentTrack);
    const artwork = metadata.artwork?.at(-1)?.src || "";
    const sampledAt = performance.timeOrigin + performance.now();
    const state = {type: "state", sampledAt, title: metadata.title, artist: metadata.artist || "",
      album: metadata.album || "", artwork, position: Number.isFinite(audio.currentTime) ? audio.currentTime : 0,
      duration: Number.isFinite(audio.duration) ? audio.duration : 0,
      playing: !audio.paused && !audio.ended, rate: audio.playbackRate || 1,
      shuffle: !!player?.shuffle, smartShuffle: !!player?.smartShuffle,
      volume: Number.isFinite(audio.volume) ? audio.volume : 1,
      source: "boring-notch-octave"};
    const fingerprint = JSON.stringify(state);
    if (force || fingerprint !== lastSnapshot) {
      lastSnapshot = fingerprint;
      window.postMessage(state, location.origin);
    }
  }
  const events = ["play", "pause", "playing", "timeupdate", "seeked", "seeking", "loadedmetadata", "durationchange", "volumechange", "ended", "emptied"];
  const descriptor = Object.getOwnPropertyDescriptor(MediaSession.prototype, "metadata");
  if (descriptor?.set) {
    Object.defineProperty(media, "metadata", {
      configurable: true,
      get: () => descriptor.get.call(media),
      set(value) { descriptor.set.call(media, value); queueMicrotask(() => publish(true)); }
    });
  }

  // Octave creates its audio engine lazily. Observe the creation once and then use media events.
  let engineValue = window.__octaveEngine;
  Object.defineProperty(window, "__octaveEngine", {
    configurable: true,
    get: () => engineValue,
    set(value) { engineValue = value; queueMicrotask(() => publish(true)); }
  });
  let storeValue = window.__octavePlayerStore;
  Object.defineProperty(window, "__octavePlayerStore", {
    configurable: true,
    get: () => storeValue,
    set(value) { storeValue = value; queueMicrotask(() => bindPlayerStore(value)); }
  });
  if (storeValue) bindPlayerStore(storeValue);

  window.addEventListener("message", event => {
    if (event.source !== window || event.origin !== location.origin || event.data?.source !== "boring-notch-command") return;
    const {action, position, sequence, volume} = event.data;
    if (action === "seek") {
      if (!Number.isFinite(position) || sequence <= latestSeek) return;
      latestSeek = sequence;
      const engine = window.__octaveEngine;
      const audio = engine?.active;
      if (audio && audio.src && !engine.isRemoteActive) {
        // Octave's cold-seek branch waits for HEAD and a media reload before
        // setting currentTime. That can remain pending in a background tab.
        // Seek the actual audible deck directly; timeupdate/seeked then update
        // Octave's store and our state from the real media element.
        engine.cancelFade?.();
        audio.currentTime = Math.max(0, Math.min(position, Number.isFinite(audio.duration) ? audio.duration : position));
      } else {
        handlers.get("seekto")?.({seekTime: position, fastSeek: false});
      }
    } else if (action === "cycleShuffle") {
      playerStore?.getState?.().cycleShuffle?.();
    } else if (action === "setVolume") {
      const audio = window.__octaveEngine?.active;
      if (audio && Number.isFinite(volume)) audio.volume = Math.max(0, Math.min(1, volume));
    } else {
      const key = {play: "play", pause: "pause", next: "nexttrack", previous: "previoustrack"}[action];
      if (key) handlers.get(key)?.();
    }
    queueMicrotask(() => publish(true));
  });

  // Capture lyrics supplied by Octave itself when its lyrics view requests them.
  const originalFetch = window.fetch;
  window.fetch = function(...args) {
    const result = originalFetch.apply(this, args);
    const url = String(args[0]?.url || args[0]);
    if (url.includes("/lyrics") && args[1]?.method === "POST") {
      result.then(async response => {
        try {
          const request = JSON.parse(args[1].body);
          const body = await response.clone().json();
          const lines = parseLyrics(body);
          if (body.success && (lines.length || body.lyrics)) window.postMessage({source: "boring-notch-octave", type: "lyrics",
            title: request.title, artist: request.artist, lines,
            plainLyrics: !body.synced && !body.richSync?.length ? body.lyrics || "" : ""}, location.origin);
        } catch (_) {}
      }).catch(() => {});
    }
    return result;
  };

  window.addEventListener("pageshow", () => publish(true));
})();
