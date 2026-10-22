"use strict";

(() => {
  if (window.__boringNotchOctaveBridge) return;
  window.__boringNotchOctaveBridge = true;
  const originalFetch = window.fetch.bind(window);
  const handlers = new Map();
  let deck = null;
  const observedDecks = new Set();
  let buffering = false;
  let lastAudioTime = null;
  let lastSnapshot = "";
  let lastPublishedAt = -Infinity;
  let latestSeek = 0;
  let seekSession = null;
  let playerStore = null;
  let unsubscribePlayer = null;
  let lyricTrackID = null;
  let lyricRequest = null;
  let lyricRetry = null;
  let lyricGeneration = 0;
  const lyricCache = new Map();
  const lyricKey = track => track?.id ? JSON.stringify([track.id, track.title, track.artist?.name]) : null;
  let publishQueued = false;
  let artworkRequest = null;
  let artworkTimeout = null;
  let currentArtworkSources = [];
  const browserArtworkURLs = new Map();
  let artworkReference = 0;
  function artworkSources(track, metadata) {
    const album = track?.album;
    const sources = [album?.cover_big, album?.cover_xl, album?.cover_medium, album?.cover_small];
    if (!track || track.title === metadata?.title) {
      const covers = [...(metadata?.artwork || [])];
      const score = cover => {
        const size = parseInt(cover.sizes, 10);
        return !size ? Infinity : size >= 500 ? size : 100000 - size;
      };
      covers.sort((a, b) => score(a) - score(b));
      sources.push(...covers.map(cover => cover.src));
    }
    let budget = 150000;
    const result = [...new Set(sources.flatMap(source => {
      if (typeof source !== "string" || !source || source.length > 7000000) return [];
      try {
        const url = new URL(source, location.origin);
        if (["blob:", "data:"].includes(url.protocol)) {
          let reference = [...browserArtworkURLs].find(([, value]) => value === url.href)?.[0];
          if (!reference) {
            reference = `page-artwork:${++artworkReference}`;
            browserArtworkURLs.set(reference, url.href);
          }
          return [reference];
        }
        return url.protocol === "https:" && url.href.length <= 150000 && !/\/(undefined|null)$/.test(url.pathname) ? [url.href] : [];
      } catch (_) { return []; }
    }))].filter(source => { budget -= source.length; return budget >= 0; }).slice(0, 8);
    for (const reference of browserArtworkURLs.keys()) if (!result.includes(reference)) browserArtworkURLs.delete(reference);
    return result;
  }

  async function requestBrowserArtwork({url, requestID}) {
    if (!currentArtworkSources.includes(url) || typeof requestID !== "string") return;
    artworkRequest?.abort();
    clearTimeout(artworkTimeout);
    const request = new AbortController();
    artworkRequest = request;
    const track = lyricKey(playerStore?.getState?.().currentTrack);
    const timeout = setTimeout(() => request.abort(), 8000);
    artworkTimeout = timeout;
    let bitmap;
    try {
      // Browser cache/session access also supports blob and local artwork URLs.
      const response = await originalFetch(browserArtworkURLs.get(url) || url, {cache: "force-cache", signal: request.signal});
      if (!response.ok) return;
      const blob = await response.blob();
      if (blob.size > 5000000 || request.signal.aborted) return;
      bitmap = await createImageBitmap(blob, {resizeWidth: 512, resizeHeight: 512, resizeQuality: "high"});
      const canvas = new OffscreenCanvas(512, 512);
      canvas.getContext("2d").drawImage(bitmap, 0, 0, 512, 512);
      const thumbnail = await canvas.convertToBlob({type: "image/jpeg", quality: 0.85});
      if (thumbnail.size > 300000 || request.signal.aborted ||
          track !== lyricKey(playerStore?.getState?.().currentTrack) || !currentArtworkSources.includes(url)) return;
      const bytes = new Uint8Array(await thumbnail.arrayBuffer());
      let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 8192) binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
      window.postMessage({source: "boring-notch-octave", type: "artwork", url, requestID, data: btoa(binary)}, location.origin);
    } catch (_) {
      // Native URL candidates and retries remain available if CORS blocks this fallback.
    } finally {
      bitmap?.close();
      clearTimeout(timeout);
      if (artworkRequest === request) artworkRequest = null;
    }
  }
  function schedulePublish() {
    if (publishQueued) return;
    publishQueued = true;
    queueMicrotask(() => { publishQueued = false; publish(true); });
  }
  const media = navigator.mediaSession;
  const originalHandler = media.setActionHandler.bind(media);
  media.setActionHandler = (action, handler) => {
    if (handler) handlers.set(action, handler);
    else handlers.delete(action);
    return originalHandler(action, handler);
  };

  function bindPlayerStore(store) {
    store = store ?? null;
    if (playerStore === store) return;
    unsubscribePlayer?.();
    playerStore = store;
    unsubscribePlayer = store?.subscribe?.((state, previous) => {
      if (state.currentTrack !== previous?.currentTrack ||
          state.shuffle !== previous?.shuffle || state.smartShuffle !== previous?.smartShuffle) schedulePublish();
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

  async function requestLyrics(track, attempt = 0) {
    const key = lyricKey(track);
    if (key === lyricTrackID && attempt === 0) return;
    lyricTrackID = key;
    const generation = ++lyricGeneration;
    clearTimeout(lyricRetry);
    lyricRequest?.abort();
    lyricRequest = null;
    if (!key) return;
    const cached = lyricCache.get(key);
    if (cached) {
      lyricCache.delete(key);
      lyricCache.set(key, cached);
      window.postMessage(cached, location.origin);
      return;
    }
    const request = new AbortController();
    lyricRequest = request;
    const timeout = setTimeout(() => request.abort(), 8000);
    const title = track.title || "";
    const artist = track.artist?.name || "";
    try {
      const response = await originalFetch("https://api.octavestreaming.com/api/lyrics", {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({id: track.id, title, artist, album: track.album?.title || "",
          duration: track.duration || 0}), signal: request.signal});
      if (!response.ok) throw new Error("Lyrics HTTP failure");
      const body = await response.json();
      if (generation !== lyricGeneration) return;
      if (request.signal.aborted) throw new Error("Lyrics timed out");
      if (!body.success) throw new Error("Lyrics unavailable");
      const message = {source: "boring-notch-octave", type: "lyrics", title, artist,
        lines: body.success ? parseLyrics(body) : [],
        plainLyrics: body.success && !body.synced && !body.richSync?.length ? body.lyrics || "" : ""};
      // Bound both retained memory and native-message size for pathological responses.
      if (JSON.stringify(message).length > 200000) throw new Error("Lyrics too large");
      lyricCache.set(key, message);
      if (lyricCache.size > 12) lyricCache.delete(lyricCache.keys().next().value);
      window.postMessage(message, location.origin);
    } catch (_) {
      if (generation !== lyricGeneration) return;
      if (attempt < 2) lyricRetry = setTimeout(() => requestLyrics(track, attempt + 1), attempt === 0 ? 750 : 2000);
      else window.postMessage({source: "boring-notch-octave", type: "lyrics", title, artist, lines: []}, location.origin);
    } finally {
      clearTimeout(timeout);
      if (lyricRequest === request) lyricRequest = null;
    }
  }

  function publish(force = false) {
    const engine = window.__octaveEngine;
    const audio = engine?.active;
    const decks = new Set([audio, engine?.a, engine?.b, engine?.airEl].filter(Boolean));
    for (const item of observedDecks) if (!decks.has(item)) {
      for (const name of events) item.removeEventListener(name, handleMediaEvent);
      observedDecks.delete(item);
    }
    for (const item of decks) if (!observedDecks.has(item)) {
      for (const name of events) item.addEventListener(name, handleMediaEvent);
      observedDecks.add(item);
    }
    if (audio !== deck) {
      deck = audio || null;
      buffering = !!audio && !audio.paused && audio.readyState < 3;
      lastAudioTime = null;
    }
    // A background tab can miss `playing` after `waiting`. Actual progress
    // repairs the clock without treating a merely ready, stalled deck as playing.
    if (buffering && lastAudioTime !== null && audio?.currentTime > lastAudioTime + 0.01) buffering = false;
    lastAudioTime = audio?.currentTime ?? null;
    const player = playerStore?.getState?.();
    requestLyrics(player?.currentTrack);
    const track = player?.currentTrack;
    const metadata = track?.title && track.title !== media.metadata?.title
      ? {title: track.title, artist: track.artist?.name || "", album: track.album?.title || ""}
      : media.metadata;
    if (!audio || !metadata?.title) {
      if (lastSnapshot && !player?.currentTrack && !metadata?.title) {
        artworkRequest?.abort();
        clearTimeout(artworkTimeout);
        currentArtworkSources = [];
        browserArtworkURLs.clear();
        lastSnapshot = "";
        window.postMessage({source: "boring-notch-octave", type: "state", title: "", artist: "",
          position: 0, duration: 0, playing: false}, location.origin);
      }
      return;
    }
    const sources = artworkSources(player?.currentTrack, metadata);
    const artwork = sources[0] || "";
    if (artwork !== currentArtworkSources[0]) {
      artworkRequest?.abort();
      clearTimeout(artworkTimeout);
    }
    currentArtworkSources = sources;
    const sampledAt = performance.timeOrigin + performance.now();
    const state = {type: "state", sampledAt, clockDiscontinuity: force === true, title: metadata.title, artist: metadata.artist || "",
      trackID: String(player?.currentTrack?.id || ""),
      album: metadata.album || "", artwork, artworks: sources, position: Number.isFinite(audio.currentTime) ? audio.currentTime : 0,
      duration: Number.isFinite(audio.duration) ? audio.duration : 0,
      playing: !audio.paused && !audio.ended, rate: buffering ? 0 : (Number.isFinite(audio.playbackRate) ? Math.max(0, audio.playbackRate) : 1),
      shuffle: !!player?.shuffle, smartShuffle: !!player?.smartShuffle,
      volume: Number.isFinite(audio.volume) ? audio.volume : 1,
      source: "boring-notch-octave"};
    // The clock advances locally. Transport metadata changes immediately;
    // position anchors are sent on discontinuities and a slow heartbeat.
    const {sampledAt: _sampledAt, position: _position, clockDiscontinuity: _clockDiscontinuity, ...metadataState} = state;
    const fingerprint = JSON.stringify(metadataState);
    if (force === true || fingerprint !== lastSnapshot || state.playing && sampledAt - lastPublishedAt >= 5000) {
      lastSnapshot = fingerprint;
      lastPublishedAt = sampledAt;
      window.postMessage(state, location.origin);
    }
  }
  const events = ["play", "pause", "playing", "waiting", "canplay", "timeupdate", "seeked", "seeking", "loadedmetadata", "durationchange", "volumechange", "ratechange", "ended", "emptied"];
  function handleMediaEvent(event) {
    const activeEvent = !event.currentTarget || event.currentTarget === window.__octaveEngine?.active;
    if (event.type === "timeupdate") {
      if (!buffering && window.__octaveEngine?.active === deck && performance.timeOrigin + performance.now() - lastPublishedAt < 5000) return;
      publish();
      return;
    }
    if (activeEvent && event.type === "waiting") buffering = true;
    else if (activeEvent && (event.type === "playing" || event.type === "canplay")) buffering = false;
    schedulePublish();
  }
  // Media events can stop in background tabs. Refresh anchors when delivery
  // resumes; a paused page needs no periodic native messages.
  setInterval(() => {
    // Recheck paused decks too: a missed pause/resume or replaced store must
    // not leave the last snapshot stuck forever. Unchanged pauses stay quiet.
    if (window.__octavePlayerStore !== playerStore) bindPlayerStore(window.__octavePlayerStore);
    publish();
  }, 5000);
  const descriptor = Object.getOwnPropertyDescriptor(MediaSession.prototype, "metadata");
  if (descriptor?.set) {
    Object.defineProperty(media, "metadata", {
      configurable: true,
      get: () => descriptor.get.call(media),
      set(value) { descriptor.set.call(media, value); schedulePublish(); }
    });
  }

  // Octave creates its audio engine lazily. Observe the creation once and then use media events.
  let engineValue = window.__octaveEngine;
  Object.defineProperty(window, "__octaveEngine", {
    configurable: true,
    get: () => engineValue,
    set(value) { engineValue = value; schedulePublish(); }
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
    const {action, position, sequence, volume, session} = event.data;
    if (action === "requestArtwork") {
      requestBrowserArtwork(event.data);
      return;
    } else if (action === "seek") {
      if (typeof session === "string" && session !== seekSession) { seekSession = session; latestSeek = 0; }
      if (!Number.isFinite(position) || !Number.isFinite(sequence) || sequence <= latestSeek) return;
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
    schedulePublish();
    if (action === "refresh") queueMicrotask(() => {
      const lyrics = lyricCache.get(lyricKey(playerStore?.getState?.().currentTrack));
      if (lyrics) window.postMessage(lyrics, location.origin);
      if (event.data.requestID) window.postMessage({source: "boring-notch-octave", type: "ready",
        requestID: event.data.requestID}, location.origin);
    });
  });

  // Capture lyrics supplied by Octave itself when its lyrics view requests them.
  window.fetch = function(...args) {
    const result = originalFetch(...args);
    const url = String(args[0]?.url || args[0]);
    if (url.includes("/lyrics") && args[1]?.method === "POST") {
      result.then(async response => {
        try {
          const request = JSON.parse(args[1].body);
          const body = await response.clone().json();
          const track = playerStore?.getState?.().currentTrack;
          if (track && (request.id != null && request.id !== track.id || request.title !== track.title || request.artist !== track.artist?.name)) return;
          const lines = parseLyrics(body);
          const message = {source: "boring-notch-octave", type: "lyrics",
            title: request.title, artist: request.artist, lines,
            plainLyrics: !body.synced && !body.richSync?.length ? body.lyrics || "" : ""};
          if (body.success && (lines.length || body.lyrics) && JSON.stringify(message).length <= 200000) {
            if (track) {
              lyricRequest?.abort();
              lyricRequest = null;
              ++lyricGeneration;
              clearTimeout(lyricRetry);
              lyricTrackID = lyricKey(track);
              lyricCache.set(lyricTrackID, message);
              if (lyricCache.size > 12) lyricCache.delete(lyricCache.keys().next().value);
            }
            window.postMessage(message, location.origin);
          }
        } catch (_) {}
      }).catch(() => {});
    }
    return result;
  };

  window.addEventListener("pageshow", () => publish(true));
  window.addEventListener("online", () => {
    if (lyricRequest === null && !lyricCache.has(lyricTrackID)) lyricTrackID = null;
    schedulePublish();
  });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) schedulePublish(); });
})();
