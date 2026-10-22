const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {once} = require('node:events');

async function until(condition) {
  const deadline = Date.now() + 3000;
  while (!condition() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 5));
  assert.ok(condition(), 'Native transport timed out');
}

function frames(buffer) {
  const result = [];
  for (let offset = 0; offset + 4 <= buffer.length;) {
    const size = buffer.readUInt32LE(offset);
    if (offset + 4 + size > buffer.length) break;
    result.push(JSON.parse(buffer.subarray(offset + 4, offset + 4 + size)));
    offset += 4 + size;
  }
  return result;
}

async function fixture(run) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'octave-native-'));
  const socketPath = path.join(directory, 'bridge.sock');
  const server = net.createServer();
  server.listen(socketPath);
  await once(server, 'listening');
  const connected = once(server, 'connection');
  const child = spawn('python3', ['-u', '-c',
    "import runpy,sys; scope=runpy.run_path('octave-brave-extension/native_host.py'); scope['main'].__globals__['SOCKET']=sys.argv[1]; scope['main']()", socketPath]);
  let output = Buffer.alloc(0), error = '', exit = null;
  child.stdout.on('data', chunk => { output = Buffer.concat([output, chunk]); });
  child.stderr.on('data', chunk => { error += chunk; });
  child.stdin.on('error', () => {});
  child.on('exit', code => { exit = code; });
  const [peer] = await connected;
  peer.on('error', () => {});
  try {
    await run({child, peer, get output() { return output; }, get error() { return error; }, get exit() { return exit; }});
  } finally {
    peer.destroy();
    child.kill();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(directory, {recursive: true, force: true});
  }
}

async function main() {
  await fixture(async f => {
    let input = '';
    f.peer.on('data', bytes => { input += bytes.toString(); });
    const message = JSON.stringify({type: 'state', title: 'Fragmented 🎵', playing: true});
    const body = Buffer.from(message), header = Buffer.alloc(4);
    header.writeUInt32LE(body.length);
    f.child.stdin.write(header.subarray(0, 2));
    f.peer.write('{"type":"command",');
    f.child.stdin.write(Buffer.concat([header.subarray(2), body.subarray(0, 8)]));
    f.child.stdin.write(body.subarray(8));
    await until(() => input.endsWith('\n'));
    assert.equal(input, message + '\n', 'Fragmented browser frames arrive intact');
    f.peer.write('"action":"pause"}\n{"type":"command","action":"play"}\n');
    await until(() => frames(f.output).length === 2);
    assert.deepEqual(frames(f.output).map(frame => frame.action), ['pause', 'play']);
    f.child.stdin.end();
    await until(() => f.exit !== null);
    assert.match(f.error, /browser closed/);
  });
  await fixture(async f => {
    const header = Buffer.alloc(4); header.writeUInt32LE(1024 * 1024 + 1);
    f.child.stdin.write(header);
    await until(() => f.exit !== null);
    assert.match(f.error, /browser message exceeded/);
  });
  await fixture(async f => {
    f.peer.write(Buffer.alloc(1024 * 1024 + 1, 120));
    await until(() => f.exit !== null);
    assert.match(f.error, /unterminated app message exceeded/);
    assert.equal(f.output.length, 0);
  });
  console.log('PASS: real Python host framing, fragmented/coalesced messages, EOF and bounded buffers');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
