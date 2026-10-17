const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Exercise the shipped parser in its browser environment, with no network.
let sampleTime = 25.125;
const heartbeats = [];
const audioListeners = new Map();
const fetchCalls = [];
const ownLyricsMessages = [];
const samples = [];
const baseFetch = async (url, options) => {
  fetchCalls.push({url, options});
  const body = {success: true, synced: false, lyrics: 'A plain lyric'};
  return {json: async () => body, clone() { return {json: async () => body}; }};
};
const window = {addEventListener() {}, postMessage() {}, fetch: baseFetch};
const sandbox = {window, navigator: {mediaSession: {setActionHandler() {}}},
  MediaSession: class {}, location: {origin: 'https://music.octavestreaming.com'},
  queueMicrotask, setInterval(fn) {heartbeats.push(fn);}, AbortController, performance: {timeOrigin: 1000000, now: () => sampleTime}, console};
Object.defineProperty(sandbox, 'fetch', {
  get: () => window.fetch,
  set: value => { window.fetch = value; }
});
const context = vm.createContext(sandbox);
const source = fs.readFileSync('octave-brave-extension/page.js', 'utf8');
vm.runInContext(source.replace(/\}\)\(\);\s*$/, 'globalThis.parseLyrics = parseLyrics;globalThis.requestLyrics = requestLyrics;})();'), context);
window.postMessage = message => {
  ownLyricsMessages.push(message);
  samples.push(message);
};
const parse = body => JSON.parse(JSON.stringify(context.parseLyrics(body)));
assert.deepEqual(parse({richSync: [{start: 10, end: 12, text: 'ਤੇਰਾ ਪਿਆਰ',
  words: [{start: 10.2, end: 10.7, word: 'ਤੇਰਾ'}, {start: 11, end: 11.6, word: 'ਪਿਆਰ'}]}]}),
  [{time: 10, end: 12, text: 'ਤੇਰਾ ਪਿਆਰ', words: [
    {start: 10.2, end: 10.7, text: 'ਤੇਰਾ'}, {start: 11, end: 11.6, text: 'ਪਿਆਰ'}]}]);
assert.deepEqual(parse({synced: true, lyrics: '[00:01.5][00:03.050]Hello\n[00:05.005]'}),
  [{time: 1.5, text: 'Hello', words: []}, {time: 3.05, text: 'Hello', words: []}, {time: 5.005, text: '', words: []}]);
assert.deepEqual(parse({synced: true, lyrics: '[00:10]<00:10>Hello <00:11>world<00:12>'})[0].words,
  [{start: 10, end: 11, text: 'Hello'}, {start: 11, end: 12, text: 'world'}]);
assert.deepEqual(parse({synced: true, lyrics: '[00:10]<00:10>Hello <00:11>world'})[0],
  {time: 10, text: 'Hello world', words: []});
assert.deepEqual(parse({synced: false, lyrics: 'A paragraph without timing'}), []);

assert.deepEqual(parse({richSync: [
  {start: 1.125, end: 4.875, text: 'lead', words: [{start: 1.125, end: 4.875, word: 'lead'}]},
  {start: 1.125, end: 2.625, text: '(ohh)', isBackground: true,
   words: [{start: 1.175, end: 2.525, word: '(ohh)', isBackground: true}]}
]}).map(line => [line.time, line.words[0].start, line.isBackground || false]),
  [[1.125, 1.125, false], [1.125, 1.175, true]]);

// The bridge's own request must bypass its window.fetch interceptor. An
// Octave-owned lyrics request must still pass through it and publish once.
async function verifyLyricsFetchRouting() {
  const publishedLyrics = () => ownLyricsMessages.filter(message => message.type === 'lyrics');
  await context.requestLyrics({id: 'fixture', title: 'Banda Kaam Ka', artist: {name: 'Chaar Diwaari'}});
  assert.equal(fetchCalls.length, 1, 'Own request reaches the underlying fetch exactly once');
  assert.equal(fetchCalls[0].url, 'https://api.octavestreaming.com/api/lyrics');
  assert.equal(JSON.parse(fetchCalls[0].options.body).title, 'Banda Kaam Ka');
  assert.equal(publishedLyrics().length, 1, 'Own request publishes a single response');
  assert.equal(publishedLyrics()[0].plainLyrics, 'A plain lyric');

  await context.fetch('https://api.octavestreaming.com/api/lyrics', {method: 'POST',
    body: JSON.stringify({title: 'Octave lyrics', artist: 'Artist'})});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fetchCalls.length, 2, 'External request reaches underlying fetch once');
  assert.equal(publishedLyrics().length, 2, 'External request is intercepted and published once');
  assert.equal(publishedLyrics()[1].title, 'Octave lyrics');
}

// The sample timestamp is captured with audio.currentTime, before transport.
context.navigator.mediaSession.metadata = {title: 'Timing fixture', artist: 'Artist'};
window.__octaveEngine = {active: {currentTime: 10.125, duration: 100, paused: false,
  playbackRate: 1, volume: 1, readyState: 4, addEventListener(name, fn) {audioListeners.set(name, fn);}, removeEventListener(name) {audioListeners.delete(name);}}};

// Restarting the native app replays exact lyrics for the current tab/track.
let listener, disconnect, reconnect;
const messages = [];
const port = () => ({postMessage: message => messages.push(message), onMessage: {addListener() {}},
  onDisconnect: {addListener(fn) {disconnect = fn;}}});
const chrome = {runtime: {connectNative: port, onMessage: {addListener(fn) {listener = fn;}}},
  tabs: {onRemoved: {addListener() {}}, onUpdated: {addListener() {}}, sendMessage: async () => {}}};
vm.runInNewContext(fs.readFileSync('octave-brave-extension/background.js', 'utf8'),
  {chrome, setTimeout(fn) {reconnect = fn;}, clearTimeout() {}});
const sender = {tab: {id: 1, url: 'https://music.octavestreaming.com/'}};
listener({type: 'state', title: 'Song', artist: 'Artist', playing: true}, sender);
const lyrics = {type: 'lyrics', title: 'Song', artist: 'Artist', lines: [{time: 1, text: 'Hello'}]};
listener(lyrics, sender);
messages.length = 0;
disconnect(); reconnect();
assert.deepEqual(messages.map(m => m.type), ['state', 'lyrics']);
assert.deepEqual(messages[1], lyrics);
listener({type: 'state', title: 'Other', artist: 'Artist', playing: true}, sender);
messages.length = 0;
disconnect(); reconnect();
assert.deepEqual(messages.map(m => m.type), ['state']);
setImmediate(() => {
  verifyLyricsFetchRouting().then(() => {
  const sample = samples.find(message => message.type === 'state');
  assert.equal(sample.sampledAt, 1000025.125);
  assert.equal(sample.position, 10.125);
  // Ninety browser timeupdate events should produce just four heartbeat
  // anchors, rather than ninety XPC/SwiftUI publications.
  samples.length = 0;
  for (let i = 1; i <= 90; i++) {
    sampleTime += 250;
    window.__octaveEngine.active.currentTime += 0.25;
    audioListeners.get('timeupdate')({type: 'timeupdate'});
  }
  assert.equal(samples.filter(m => m.type === 'state').length, 4);
  samples.length = 0;
  window.__octaveEngine.active.paused = true;
  audioListeners.get('pause')({type: 'pause'});
  assert.equal(samples.at(-1).playing, false);
  assert.equal(samples.at(-1).clockDiscontinuity, true);
  samples.length = 0;
  sampleTime += 6000;
  heartbeats[0]();
  assert.equal(samples.length, 0, 'Paused playback needs no heartbeat');
  window.__octaveEngine.active.currentTime -= 0.025;
  audioListeners.get('seeked')({type: 'seeked'});
  assert.equal(samples.at(-1).position, window.__octaveEngine.active.currentTime);
  assert.equal(samples.at(-1).clockDiscontinuity, true, 'Even small seeks rebase immediately');
  window.__octaveEngine.active.paused = false;
  window.__octaveEngine.active.playbackRate = 2;
  audioListeners.get('ratechange')({type: 'ratechange'});
  assert.equal(samples.at(-1).rate, 2);
  audioListeners.get('waiting')({type: 'waiting'});
  assert.equal(samples.at(-1).rate, 0, 'Freeze the native clock while buffering');
  audioListeners.get('playing')({type: 'playing'});
  assert.equal(samples.at(-1).rate, 2);
  sampleTime += 5000;
  const previousCount = samples.length;
  heartbeats[0]();
  assert.equal(samples.length, previousCount + 1, 'Heartbeat works without timeupdate');
  console.log('Octave parser, fetch routing, overlapping vocals, precise clock and reconnect tests passed');
  }).catch(error => { console.error(error); process.exitCode = 1; });
});
