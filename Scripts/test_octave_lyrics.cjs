const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Exercise the shipped parser in its browser environment, with no network.
const window = {addEventListener() {}, postMessage() {}};
const context = vm.createContext({window, navigator: {mediaSession: {setActionHandler() {}}},
  MediaSession: class {}, location: {origin: 'https://music.octavestreaming.com'},
  queueMicrotask, AbortController, performance: {timeOrigin: 1000000, now: () => 25.125}, fetch: async () => ({}), console});
const source = fs.readFileSync('octave-brave-extension/page.js', 'utf8');
vm.runInContext(source.replace(/\}\)\(\);\s*$/, 'globalThis.parseLyrics = parseLyrics;globalThis.requestLyrics = requestLyrics;})();'), context);
const lyricRequests = [];
context.fetch = async (url, options) => {
  lyricRequests.push({url, options});
  return {json: async () => ({success: false})};
};
context.requestLyrics({id: 'fixture', title: 'Banda Kaam Ka', artist: {name: 'Chaar Diwaari'}});
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

// The sample timestamp is captured with audio.currentTime, before transport.
const samples = [];
window.postMessage = message => samples.push(message);
context.navigator.mediaSession.metadata = {title: 'Timing fixture', artist: 'Artist'};
window.__octaveEngine = {active: {currentTime: 10.125, duration: 100, paused: false,
  playbackRate: 1, volume: 1, addEventListener() {}, removeEventListener() {}}};

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
  assert.equal(lyricRequests[0].url, 'https://api.octavestreaming.com/api/lyrics');
  assert.equal(JSON.parse(lyricRequests[0].options.body).title, 'Banda Kaam Ka');
  const sample = samples.find(message => message.type === 'state');
  assert.equal(sample.sampledAt, 1000025.125);
  assert.equal(sample.position, 10.125);
  console.log('Octave parser, overlapping vocals, precise clock and reconnect tests passed');
});
