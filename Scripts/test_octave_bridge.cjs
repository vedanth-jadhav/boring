const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const flush = () => new Promise(resolve => setImmediate(resolve));
function timers() {
  let next = 0;
  const pending = new Map();
  return {
    pending,
    setTimeout(fn, delay) { pending.set(++next, {fn, delay}); return next; },
    clearTimeout(id) { pending.delete(id); },
    async run(delay) {
      const entry = [...pending].find(([, timer]) => timer.delay === delay);
      assert.ok(entry, `Expected a ${delay}ms timer`);
      pending.delete(entry[0]);
      entry[1].fn();
      await flush();
    }
  };
}

function page(source = fs.readFileSync('octave-brave-extension/page.js', 'utf8')) {
  const timer = timers();
  const messages = [], fetches = [], audioListeners = new Map(), listeners = new Map(), intervals = [];
  let now = 0, fingerprints = 0, subscriber;
  const track = id => ({id, title: id, artist: {name: 'Artist'}});
  let player = {currentTrack: null};
  let fetch = async () => ({ok: true, json: async () => ({success: true, lyrics: 'words'})});
  class MediaSession {
    get metadata() { return this.value; }
    set metadata(value) { this.value = value; }
    setActionHandler() {}
  }
  const media = new MediaSession();
  media.metadata = {title: 'A', artist: 'Artist', artwork: [
    {src: 'https://images.example/small', sizes: '96x96'},
    {src: 'https://images.example/display', sizes: '512x512'},
    {src: 'https://images.example/original', sizes: '4096x4096'}]};
  const makeAudio = events => ({currentTime: 0, duration: 100, playbackRate: 1, volume: 1, readyState: 4, paused: false,
    addEventListener(name, fn) { events.set(name, fn); },
    removeEventListener(name) { events.delete(name); }});
  const audio = makeAudio(audioListeners), secondaryListeners = new Map(), secondary = makeAudio(secondaryListeners);
  const window = {__octaveEngine: {active: audio, a: audio, b: secondary},
    __octavePlayerStore: {getState: () => player, subscribe(fn) { subscriber = fn; return () => {}; }},
    fetch(...args) { fetches.push(args); return fetch(...args); },
    postMessage(message) { messages.push(message); },
    addEventListener(name, fn) { listeners.set(name, fn); }};
  const document = {hidden: false, addEventListener(name, fn) { listeners.set(name, fn); }};
  const context = vm.createContext({window, document, navigator: {mediaSession: media}, MediaSession,
    location: {origin: 'https://music.octavestreaming.com'}, AbortController, queueMicrotask, URL, Uint8Array, btoa,
    createImageBitmap: async () => ({close() {}}),
    OffscreenCanvas: class {
      getContext() { return {drawImage() {}}; }
      async convertToBlob() { return {size: 3, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer}; }
    },
    setTimeout: timer.setTimeout, clearTimeout: timer.clearTimeout, setInterval(fn) { intervals.push(fn); },
    performance: {timeOrigin: 1000000, now: () => now},
    JSON: {parse: JSON.parse, stringify(value) {
      if (value?.type === 'state') fingerprints++;
      return JSON.stringify(value);
    }}});
  vm.runInContext(source, context);
  return {messages, fetches, timer, media, audio, secondary, window, listeners, track, intervals,
    get fingerprints() { return fingerprints; },
    setFetch(fn) { fetch = fn; },
    update(id) {
      const previous = player;
      player = {...player, currentTrack: id === null ? null : typeof id === 'object' ? id : track(id)};
      media.metadata = {...media.metadata, title: player.currentTrack?.title || 'A'};
      subscriber(player, previous);
    },
    advance(ms) { now += ms; audio.currentTime += ms / 1000; },
    event(name) { audioListeners.get(name)({type: name, currentTarget: audio}); },
    secondaryEvent(name) { secondaryListeners.get(name)({type: name, currentTarget: secondary}); }
  };
}

async function pageChecks() {
  const p = page();
  await flush();
  assert.equal(p.messages.at(-1).artwork, 'https://images.example/display');
  p.messages.length = 0;
  const fingerprints = p.fingerprints;
  for (let i = 0; i < 90; i++) { p.advance(250); p.event('timeupdate'); }
  assert.equal(p.fingerprints - fingerprints, 4, 'Routine updates skip snapshot construction');
  assert.equal(p.messages.length, 4, 'Keep the five-second clock heartbeat');
  p.messages.length = 0;
  for (const name of ['play', 'canplay', 'playing', 'durationchange', 'loadedmetadata']) p.event(name);
  await flush();
  assert.equal(p.messages.length, 1, 'One snapshot for a synchronous media-event burst');
  function command(data) {
    p.listeners.get('message')({source: p.window, origin: 'https://music.octavestreaming.com',
      data: {source: 'boring-notch-command', ...data}});
  }
  p.audio.src = 'https://audio.example/track';
  command({action: 'seek', position: 25, sequence: 50, session: 'first-app'});
  command({action: 'seek', position: 5, sequence: 49, session: 'first-app'});
  assert.equal(p.audio.currentTime, 25, 'Out-of-order seeks are ignored');
  command({action: 'seek', position: 8, sequence: 1, session: 'restarted-app'});
  assert.equal(p.audio.currentTime, 8, 'Seeks recover when the native app restarts');

  p.update('A');
  await flush();
  assert.equal(p.fetches.length, 1);
  p.update('B');
  await flush();
  p.messages.length = 0;
  p.update('A');
  await flush();
  assert.equal(p.fetches.length, 2, 'Returning to a cached song requires no lyrics network request');
  assert.equal(p.messages.filter(m => m.type === 'lyrics').length, 1);
  p.messages.length = 0;
  command({action: 'refresh'});
  await flush();
  assert.deepEqual(p.messages.map(m => m.type), ['state', 'lyrics'], 'Refresh restores state before cached lyrics');

  let resolveOld;
  p.setFetch(() => new Promise(resolve => { resolveOld = resolve; }));
  p.update('Old');
  await flush();
  const oldSignal = p.fetches.at(-1)[1].signal;
  p.setFetch(async () => ({ok: true, json: async () => ({success: true, lyrics: 'new'})}));
  p.update('New');
  await flush();
  p.messages.length = 0;
  resolveOld({ok: true, json: async () => ({success: true, lyrics: 'stale'})});
  await flush();
  assert.equal(oldSignal.aborted, true);
  assert.equal(p.messages.length, 0, 'Late responses cannot overwrite the new song');

  const retry = page();
  retry.setFetch(async () => { throw new Error('offline'); });
  retry.update('Retry');
  await flush();
  retry.setFetch(async () => ({ok: true, json: async () => ({success: true, lyrics: 'recovered'})}));
  await retry.timer.run(750);
  assert.equal(retry.fetches.length, 2);
  assert.equal(retry.messages.at(-1).plainLyrics, 'recovered', 'Lyrics retry without another playback event');

  const timeout = page();
  timeout.setFetch((_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new Error('aborted')));
  }));
  timeout.update('Timeout');
  await flush();
  await timeout.timer.run(8000);
  timeout.setFetch(async () => ({ok: false, json: async () => ({})}));
  await timeout.timer.run(750);
  await timeout.timer.run(2000);
  assert.equal(timeout.fetches.length, 3, 'Network and HTTP retries are bounded');
  assert.equal(timeout.timer.pending.size, 0, 'No leaked timeout or retry timers');
  assert.equal(timeout.messages.at(-1).lines.length, 0);
  timeout.listeners.get('online')();
  await flush();
  assert.equal(timeout.fetches.length, 4, 'Restored network can recover exhausted requests');
  timeout.update(null);
  await flush();
  assert.equal(timeout.timer.pending.size, 0, 'Clearing the track cancels pending retries');

  // An Octave-owned request from an earlier song must also be rejected.
  let resolveIntercepted;
  p.setFetch(() => new Promise(resolve => { resolveIntercepted = resolve; }));
  const intercepted = p.window.fetch('https://api.octavestreaming.com/api/lyrics', {method: 'POST',
    body: JSON.stringify({id: 'Old', title: 'Old', artist: 'Artist'})});
  resolveIntercepted({clone: () => ({json: async () => ({success: true, lyrics: 'stale'})})});
  await intercepted;
  await flush();
  assert.equal(p.messages.length, 0);

  // The LRU has a fixed capacity, even over a long playlist.
  const cache = page();
  for (let i = 0; i < 14; i++) { cache.update(String(i)); await flush(); }
  cache.update('13'); await flush();
  assert.equal(cache.fetches.length, 14);
  cache.update('0'); await flush();
  assert.equal(cache.fetches.length, 15, 'Old lyrics are evicted');
  console.log('PASS: snapshot fast path, event coalescing, cover selection, lyrics cache/retry/timeout/cancellation');
}

async function artworkAndDeckChecks() {
  const p = page();
  await flush();
  p.audio.paused = true;
  p.window.__octaveEngine.active = p.secondary;
  p.messages.length = 0;
  p.secondaryEvent('playing');
  await flush();
  assert.equal(p.messages.at(-1).playing, true, 'The incoming deck publishes immediately after a handoff');
  p.event('waiting');
  await flush();
  assert.equal(p.messages.at(-1).rate, 1, 'Inactive-deck buffering cannot freeze the playing clock');
  p.secondary.paused = true;
  p.window.__octaveEngine.active = p.audio;
  p.intervals[0]();
  assert.equal(p.messages.at(-1).playing, false, 'Heartbeat can repair a missed deck switch even when the old deck is paused');

  p.update({...p.track('Store cover'), album: {cover_big: '/covers/500.jpg', cover_xl: 'https://images.example/1000.jpg'}});
  p.media.metadata = {...p.media.metadata, artwork: []};
  await flush();
  assert.equal(p.messages.filter(m => m.type === 'state').at(-1).artwork, 'https://music.octavestreaming.com/covers/500.jpg',
    'Track-store cover works without Media Session artwork, including relative paths');
  p.update({...p.track('Local'), album: {cover_big: 'blob:https://music.octavestreaming.com/cover'}});
  await flush();
  const localReference = p.messages.filter(m => m.type === 'state').at(-1).artwork;
  assert.ok(localReference.startsWith('page-artwork:'), 'Browser-local URLs use small references on the wire');
  p.setFetch(async () => ({ok: true, blob: async () => ({size: 100})}));
  p.messages.length = 0;
  const command = data => p.listeners.get('message')({source: p.window, origin: 'https://music.octavestreaming.com',
    data: {source: 'boring-notch-command', action: 'requestArtwork', ...data}});
  command({url: localReference, requestID: 'fixture'});
  await flush();
  const artwork = p.messages.find(m => m.type === 'artwork');
  assert.equal(artwork.requestID, 'fixture');
  assert.equal(artwork.data, 'AQID', 'Browser-local cover becomes a bounded thumbnail payload');
  const calls = p.fetches.length;
  command({url: 'https://unrelated.example/private', requestID: 'untrusted'});
  await flush();
  assert.equal(p.fetches.length, calls, 'Artwork commands can only fetch current cover candidates');
  let completeCover;
  p.setFetch(url => url.startsWith('blob:') ? new Promise(resolve => { completeCover = resolve; }) :
    Promise.resolve({ok: true, json: async () => ({success: true, lyrics: 'new song'})}));
  command({url: localReference, requestID: 'old-cover'});
  p.update({...p.track('Next'), album: {cover_big: 'https://images.example/next'}});
  await flush();
  p.messages.length = 0;
  completeCover({ok: true, blob: async () => ({size: 100})});
  await flush();
  assert.equal(p.messages.filter(m => m.type === 'artwork').length, 0, 'A browser thumbnail finishing after a skip is discarded');
  p.update(null); await flush();
  p.messages.length = 0;
  p.media.metadata = null; await flush();
  assert.equal(p.messages.at(-1).title, '', 'Explicitly cleared media produces an empty state');
  const inline = page();
  inline.update({...inline.track('Inline'), album: {cover_big: 'data:image/jpeg;base64,' + 'A'.repeat(250000)}});
  await flush();
  const inlineState = inline.messages.filter(m => m.type === 'state').at(-1);
  assert.ok(inlineState.artwork.startsWith('page-artwork:') && JSON.stringify(inlineState).length < 2000,
    'Large inline covers never inflate playback snapshots');
  console.log('PASS: dual-deck handoffs, inactive buffering, store/relative/blob artwork and explicit media clearing');
}

async function playbackRecoveryChecks() {
  const p = page();
  await flush();
  p.audio.paused = true;
  p.intervals[0]();
  assert.equal(p.messages.at(-1).playing, false, 'Polling repairs a missed pause event on the same deck');
  const pausedCount = p.messages.length;
  p.advance(6000); p.intervals[0]();
  assert.equal(p.messages.length, pausedCount, 'An unchanged paused page does not send periodic native snapshots');
  p.audio.paused = false;
  p.intervals[0]();
  assert.equal(p.messages.at(-1).playing, true, 'Polling repairs a missed resume event');
  p.event('waiting'); await flush();
  assert.equal(p.messages.at(-1).rate, 0);
  p.intervals[0]();
  assert.equal(p.messages.at(-1).rate, 0, 'A ready but non-advancing deck remains correctly buffered');
  p.advance(250); p.event('timeupdate');
  assert.equal(p.messages.at(-1).rate, 1, 'Real clock progress repairs a lost playing event after buffering');
  p.update('Store fallback'); await flush();
  p.media.metadata = null; await flush();
  assert.equal(p.messages.at(-1).title, 'Store fallback', 'A playing track is still observed when Media Session metadata disappears');
  p.media.metadata = {title: 'Old metadata', artist: 'Old artist'}; await flush();
  assert.equal(p.messages.at(-1).title, 'Store fallback', 'Stale Media Session metadata cannot restore the previous song');
  const replacement = {currentTrack: p.track('Replacement store'), shuffle: true};
  Object.defineProperty(p.window, '__octavePlayerStore', {value: {getState: () => replacement}, configurable: true});
  p.intervals[0]();
  assert.equal(p.messages.at(-1).title, 'Replacement store', 'Polling rebinds a store replaced without invoking the original hook');
  const states = p.messages.filter(m => m.type === 'state').length;
  p.listeners.get('message')({source: p.window, origin: 'https://music.octavestreaming.com',
    data: {source: 'boring-notch-command', action: 'refresh', requestID: 'health-check'}});
  await flush();
  const ready = p.messages.find(m => m.type === 'ready' && m.requestID === 'health-check');
  assert.ok(ready);
  assert.equal(p.messages.filter(m => m.type === 'state').length, states + 1, 'Page health acknowledgement follows a fresh snapshot');
  console.log('PASS: missed pause/resume, lost buffering event, missing/stale metadata, replaced store and page health handshake');
}

async function contentChecks() {
  const timer = timers(), sent = [], posted = [];
  let receive, command, reject = true, hang = false, resolveHung;
  const window = {addEventListener(_name, fn) { receive = fn; }, postMessage(message) { posted.push(message); }};
  const chrome = {runtime: {id: 'extension', sendMessage: async message => {
    sent.push(message);
    if (hang) return new Promise(resolve => { resolveHung = resolve; });
    if (reject) throw new Error('worker restarting');
    return {accepted: true};
  }, onMessage: {addListener(fn) { command = fn; }}}};
  vm.runInNewContext(fs.readFileSync('octave-brave-extension/content.js', 'utf8'),
    {window, chrome, location: {origin: 'https://music.octavestreaming.com'},
      setTimeout: timer.setTimeout, clearTimeout: timer.clearTimeout});
  const publish = data => receive({source: window, origin: 'https://music.octavestreaming.com',
    data: {source: 'boring-notch-octave', ...data}});
  publish({type: 'state', title: 'Old', artist: 'Artist'});
  await flush();
  publish({type: 'lyrics', title: 'Old', artist: 'Artist', lines: []});
  publish({type: 'state', title: 'Latest', artist: 'Artist', playing: false});
  reject = false;
  await timer.run(100);
  assert.deepEqual(sent.map(m => m.title), ['Old', 'Latest'], 'Failed transport retains the latest pause and discards stale lyrics');
  assert.equal(timer.pending.size, 0);
  const originalListener = receive, originalCommand = command, postedCount = posted.length;
  vm.runInNewContext(fs.readFileSync('octave-brave-extension/content.js', 'utf8'),
    {window, chrome, location: {origin: 'https://music.octavestreaming.com'},
      setTimeout: timer.setTimeout, clearTimeout: timer.clearTimeout});
  assert.equal(receive, originalListener);
  assert.equal(command, originalCommand);
  assert.equal(posted.length, postedCount, 'Recovery injection is idempotent and cannot duplicate listeners or startup snapshots');
  let acknowledged;
  command({type: 'command', action: 'seek', session: 'app', sequence: 1}, {}, value => { acknowledged = value; });
  assert.equal(posted.at(-1).session, 'app');
  assert.equal(acknowledged.accepted, true);
  let refreshReply;
  assert.equal(command({type: 'command', action: 'refresh'}, {}, value => {refreshReply = value;}), true);
  assert.equal(refreshReply, undefined, 'Refresh waits for the page observer rather than acknowledging the relay only');
  publish({type: 'ready', requestID: posted.at(-1).requestID});
  assert.equal(refreshReply.accepted, true);
  refreshReply = undefined;
  command({type: 'command', action: 'refresh'}, {}, value => {refreshReply = value;});
  await timer.run(2000);
  assert.equal(refreshReply.accepted, false, 'Missing MAIN-world observer is reported for automatic repair');
  reject = true;
  publish({type: 'state', title: 'Offline', artist: 'Artist'}); await flush();
  for (const delay of [100, 200, 400, 800, 1600]) await timer.run(delay);
  reject = false;
  await timer.run(3200);
  assert.equal(sent.at(-1).title, 'Offline', 'Final paused snapshot recovers after prolonged failure without a new event');
  assert.equal(timer.pending.size, 0);
  hang = true;
  publish({type: 'state', title: 'Hung', artist: 'Artist'}); await flush();
  publish({type: 'state', title: 'Recovered', artist: 'Artist'}); await flush();
  await timer.run(3000);
  hang = false;
  await timer.run(100);
  assert.equal(sent.at(-1).title, 'Recovered', 'An unresolved acknowledgement cannot block all subsequent playback updates');
  resolveHung({accepted: true}); await flush();
  assert.equal(timer.pending.size, 0, 'Late acknowledgements cannot restart or clear the recovered queue');
  chrome.runtime.id = undefined;
  publish({type: 'state', title: 'Invalidated', artist: 'Artist'}); await flush();
  assert.equal(timer.pending.size, 0, 'Reloaded-away content context stops retrying');
  console.log('PASS: content acknowledgement deadline, prolonged outage recovery, latest-value queue and context invalidation');
}

async function backgroundChecks() {
  const timer = timers(), ports = [], commands = [], intervals = [], injections = [];
  let now = 1000000, alarmListener;
  let receive, removed, updated, committed, failCommand = false;
  const chrome = {runtime: {onMessage: {addListener(fn) { receive = fn; }}, connectNative() {
    const port = {messages: [], disconnected: false, failPost: false,
      postMessage(message) { if (this.failPost) throw new Error('port closed'); this.messages.push(message); },
      disconnect() { this.disconnected = true; this.closed?.(); },
      onMessage: {addListener(fn) { port.command = fn; }},
      onDisconnect: {addListener(fn) { port.closed = fn; }}};
    ports.push(port); return port;
  }}, tabs: {query: async () => [{id: 7}],
    sendMessage: async (id, message) => { commands.push({id, message}); if (failCommand) throw new Error('closed'); return {accepted: true}; },
    onRemoved: {addListener(fn) { removed = fn; }}, onUpdated: {addListener(fn) { updated = fn; }}},
    webNavigation: {onCommitted: {addListener(fn) {committed = fn;}}},
    alarms: {onAlarm: {addListener(fn) {alarmListener = fn;}}, get: async () => null,
      create: async (name, options) => assert.equal(options.periodInMinutes, 0.5)},
    scripting: {executeScript: async options => {injections.push(options);}}};
  vm.runInNewContext(fs.readFileSync('octave-brave-extension/background.js', 'utf8'),
    {chrome, console, Date: {now: () => now}, setInterval(fn) {intervals.push(fn);},
      setTimeout: timer.setTimeout, clearTimeout: timer.clearTimeout});
  await flush();
  assert.equal(ports.length, 0, 'No idle native host before a media tab responds');
  assert.equal(commands[0].id, 7, 'Worker restart refreshes existing paused tabs');
  function state(id, playing = true, title = 'Song') {
    receive({type: 'state', title, artist: 'Artist', playing, position: 0, duration: 100}, {tab: {id, url: 'https://music.octavestreaming.com/'}});
  }
  state(7);
  assert.equal(ports[0].messages.length, 1, 'First snapshot is delivered once');
  state(7);
  assert.equal(ports[0].messages.length, 2, 'Subsequent snapshots are delivered once');
  state(17, true, 'New playing tab');
  state(7);
  assert.equal(ports[0].messages.at(-1).title, 'New playing tab', 'A heartbeat cannot steal selection from newer playback');
  removed(17);
  const beforeStaleLyrics = ports[0].messages.length;
  receive({type: 'lyrics', title: 'Old', artist: 'Artist', lines: []}, {tab: {id: 7, url: 'https://music.octavestreaming.com/'}});
  assert.equal(ports[0].messages.length, beforeStaleLyrics, 'Stale lyrics are never sent to the app');
  ports[0].closed();
  await timer.run(250);
  assert.equal(ports.length, 2);
  assert.equal(ports[1].messages.length, 1);
  ports[1].closed(); await timer.run(500);
  ports[2].closed(); await timer.run(1000);
  assert.equal(ports.length, 4, 'Persistent failures back off');
  state(7);
  ports[3].failPost = true;
  state(7);
  await timer.run(250);
  assert.equal(ports[3].disconnected, true, 'A synchronous post failure recovers');
  state(8, false, 'Paused');
  removed(7);
  assert.equal(ports[4].messages.at(-1).title, 'Paused', 'Closing the playing tab selects a paused fallback');
  state(9, true, 'Other');
  failCommand = true;
  ports[4].command({type: 'command', action: 'play'});
  await flush();
  failCommand = false;
  assert.equal(ports[4].messages.at(-1).title, 'Other', 'A transient command failure cannot blank active playback');
  removed(9);
  assert.equal(ports[4].messages.at(-1).title, 'Paused', 'Closing a media tab still selects a paused fallback');
  committed({tabId: 8, frameId: 0, documentId: 'outside', url: 'https://example.com/'});
  assert.equal(ports[4].messages.at(-1).type, 'gone');
  await timer.run(1000);
  assert.equal(ports[4].disconnected, true, 'Last tab releases the idle native host');
  assert.equal(timer.pending.size, 0, 'Idle host does not reconnect');
  const docState = (documentId, sampledAt, title = 'Document song') => receive({type: 'state', title, artist: 'Artist',
    playing: true, position: sampledAt, duration: 100, sampledAt},
    {frameId: 0, documentId, tab: {id: 20, url: 'https://music.octavestreaming.com/'}});
  docState('first', 100);
  const currentPort = ports.at(-1);
  const beforeOldSample = currentPort.messages.length;
  receive({type: 'state', title: 'Bad', artist: 'Artist', playing: true, position: 0, duration: 100, artworks: {}},
    {tab: {id: 20, url: 'https://music.octavestreaming.com/'}});
  assert.equal(currentPort.messages.length, beforeOldSample, 'Malformed artwork metadata is rejected before native delivery');
  docState('first', 90);
  assert.equal(currentPort.messages.length, beforeOldSample, 'Older snapshots cannot rewind current state');
  for (let i = 0; i < 5; i++) {
    const artistURL = `https://music.octavestreaming.com/artist/${108412192 + i}`;
    updated(20, {status: 'loading', url: artistURL}, {url: artistURL});
    assert.equal(currentPort.messages.at(-1).title, 'Document song', 'Artist navigation must never send gone while the same document plays');
    docState('first', 101 + i);
    assert.equal(currentPort.messages.at(-1).sampledAt, 101 + i, 'Playback anchors continue through repeated artist navigation');
    updated(20, {status: 'complete'}, {url: artistURL});
  }
  updated(20, {status: 'loading'});
  docState('first', 110);
  assert.equal(currentPort.messages.at(-1).sampledAt, 110, 'An aborted navigation cannot retire a still-playing document');
  receive({type: 'lyrics', title: 'Document song', artist: 'Artist', lines: []},
    {frameId: 0, documentId: 'first', tab: {id: 20, url: 'https://music.octavestreaming.com/artist/108412192'}});
  assert.equal(currentPort.messages.at(-1).type, 'lyrics', 'Lyrics continue from the same document after browsing artists');
  committed({tabId: 20, frameId: 0, documentId: 'first', url: 'https://music.octavestreaming.com/artist/108412192'});
  docState('first', 111);
  assert.equal(currentPort.messages.at(-1).sampledAt, 111, 'A commit retaining the same document preserves playback');
  committed({tabId: 20, frameId: 2, documentId: 'iframe', url: 'https://example.com/'});
  assert.equal(currentPort.messages.at(-1).title, 'Document song', 'Subframe navigation cannot clear top-frame playback');
  committed({tabId: 20, frameId: 0, documentId: 'replacement', url: 'https://music.octavestreaming.com/'});
  docState('replacement', 200, 'Replacement document');
  docState('first', 300, 'Retired document');
  assert.equal(currentPort.messages.at(-1).title, 'Replacement document', 'Late updates from a navigated-away document are ignored');
  committed({tabId: 20, frameId: 0, documentId: 'third', url: 'https://music.octavestreaming.com/'});
  docState('third', 400, 'Third document');
  docState('first', 500, 'Very old document');
  docState('replacement', 500, 'Old document');
  assert.equal(currentPort.messages.at(-1).title, 'Third document', 'All earlier documents stay rejected across multiple full navigations');
  receive({type: 'state', title: 'Cached page', artist: 'Artist', playing: true, position: 0, duration: 100},
    {frameId: 0, documentId: 'third', documentLifecycle: 'cached', tab: {id: 20, url: 'https://music.octavestreaming.com/'}});
  assert.equal(currentPort.messages.at(-1).title, 'Third document', 'Inactive document lifecycles cannot take over playback');
  committed({tabId: 20, frameId: 0, documentId: 'replacement', url: 'https://music.octavestreaming.com/'});
  docState('replacement', 200, 'Restored document');
  assert.equal(currentPort.messages.at(-1).title, 'Restored document', 'Back/forward cache restoration accepts the newly committed document again');
  failCommand = true;
  currentPort.command({type: 'command', action: 'pause'});
  docState('replacement', 201, 'Still healthy');
  await flush();
  failCommand = false;
  assert.equal(currentPort.messages.at(-1).title, 'Still healthy', 'A delayed send failure cannot delete freshly received state');
  removed(20); await timer.run(1000);
  state(30);
  const profilePort = ports.at(-1), profileCount = ports.length;
  profilePort.command({type: 'superseded'});
  state(30);
  assert.equal(ports.length, profileCount, 'A replaced browser profile does not fight the new connection on every heartbeat');
  state(30, false);
  state(30, true);
  assert.equal(ports.length, profileCount + 1, 'Resuming playback can reclaim the native bridge');
  removed(30); await timer.run(1000);
  state(40);
  const stalledPort = ports.at(-1);
  intervals[0]();
  const firstProbe = stalledPort.messages.at(-1);
  assert.equal(firstProbe.type, 'ping');
  now += 5000;
  stalledPort.command({type: 'pong', nonce: 'wrong'});
  intervals[0]();
  assert.equal(stalledPort.disconnected, false, 'Probe allows normal transport latency');
  now += 5000;
  intervals[0]();
  assert.equal(stalledPort.disconnected, true, 'An open but unresponsive native host is replaced');
  await timer.run(250);
  const healthyPort = ports.at(-1);
  intervals[0]();
  healthyPort.command({type: 'pong', nonce: healthyPort.messages.at(-1).nonce});
  now += 15000;
  intervals[0]();
  await flush();
  assert.equal(healthyPort.disconnected, false, 'The current native host remains connected after an acknowledged probe');
  assert.ok(commands.some(c => c.id === 40 && c.message.action === 'refresh'), 'Stale playback requests a fresh page sample');
  healthyPort.command({type: 'pong', nonce: healthyPort.messages.at(-1).nonce});
  removed(40); await timer.run(1000);
  failCommand = true;
  alarmListener({name: 'octave-bridge-recovery'});
  await flush();
  assert.deepEqual(injections.slice(-2).map(i => i.files[0]), ['page.js', 'content.js'], 'A worker alarm repairs missing page and content listeners');
  assert.equal(injections.at(-2).world, 'MAIN');
  failCommand = false;
  const beforeAudible = commands.length;
  updated(7, {audible: true}, {url: 'https://music.octavestreaming.com/'});
  await flush();
  assert.ok(commands.length > beforeAudible, 'Browser audibility rediscovers playback even without a media event');
  assert.equal(timer.pending.size, 0, 'Watchdog recovery leaves no dangling deadline timers');
  console.log('PASS: artist navigation continuity, aborted loads, document replacement/cache restoration, worker restart, reconnect and idle cleanup');
}

async function main() {
  await pageChecks();
  await artworkAndDeckChecks();
  await playbackRecoveryChecks();
  await contentChecks();
  await backgroundChecks();
  if (process.argv.includes('--benchmark')) {
    const original = require('node:child_process').execFileSync('git', ['show', 'HEAD:octave-brave-extension/page.js'], {encoding: 'utf8'});
    const before = page(original), after = page();
    await flush();
    const oldCount = before.fingerprints, newCount = after.fingerprints;
    for (let i = 0; i < 90; i++) {
      for (const p of [before, after]) { p.advance(250); p.event('timeupdate'); }
    }
    console.log(`Controlled 90-event workload: snapshot serializations ${before.fingerprints - oldCount} -> ${after.fingerprints - newCount}`);
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
