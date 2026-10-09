const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { once } = require("node:events");
const { NativeClient } = require("../native-client.cjs");

const geometry = import("../renderer/geometry.mjs");
test("spring keeps the same physical motion at 60 and 144 Hz", async () => {
  const { Spring } = await geometry;
  const a = new Spring(204),
    b = new Spring(204);
  a.set(640);
  b.set(640);
  for (let i = 0; i < 18; i++) a.step(1 / 60);
  for (let i = 0; i < 43; i++) b.step(0.3 / 43);
  assert.ok(Math.abs(a.value - b.value) < 0.00001);
  assert.ok(a.value > 630 && a.value < 640);
});
test("retargeting preserves position and velocity; closing settles without overshoot", async () => {
  const { Spring } = await geometry;
  const spring = new Spring(34);
  spring.set(190);
  spring.step(0.08);
  const position = spring.value,
    velocity = spring.velocity;
  spring.set(34);
  assert.equal(spring.value, position);
  assert.equal(spring.velocity, velocity);
  for (let i = 0; i < 90; i++) {
    spring.step(1 / 60);
    assert.ok(spring.value >= 34 && spring.value <= 190);
  }
  assert.equal(spring.value, 34);
  assert.equal(spring.active, false);
});
test("reduced motion snaps geometry and stops all spring work", async () => {
  const { Spring } = await geometry;
  const spring = new Spring(204);
  spring.set(640, true);
  assert.equal(spring.value, 640);
  assert.equal(spring.active, false);
});
test("renderer clock uses the sampled rate and holds while paused", async () => {
  const { playbackPosition } = await geometry;
  const now = Date.now();
  const media = {
    sampled: new Date(now - 1000).toISOString(),
    position: 10,
    rate: 2,
    duration: 100,
    playing: true,
  };
  assert.equal(playbackPosition(media, now), 12);
  media.playing = false;
  assert.equal(playbackPosition(media, now + 2000), 10);
  media.playing = true;
  assert.equal(playbackPosition(media, now + 200000), 100);
});
test("backing lyrics only appear within their actual timing range", async () => {
  const { currentLine } = await geometry;
  const lines = [
    { time: 1, text: "Lead", words: [] },
    { time: 2, end: 4, text: "(backing)", isBackground: true, words: [] },
  ];
  assert.equal(currentLine(lines, 3).text, "Lead");
  assert.equal(currentLine(lines, 3, true).text, "(backing)");
  assert.equal(currentLine(lines, 5, true), null);
});
test("helper client parses fragments and correlates out-of-order replies", async (t) => {
  const client = new NativeClient(process.execPath, [
    path.join(__dirname, "fixtures/helper.cjs"),
  ]);
  t.after(() => client.close());
  const [event, data] = await once(client, "event");
  assert.equal(event, "ready");
  assert.equal(data, true);
  const first = client.call("echo", { value: 1, delay: 30 });
  const second = client.call("echo", { value: 2 });
  assert.equal((await second).value, 2);
  assert.equal((await first).value, 1);
  assert.equal(client.pending.size, 0);
  await assert.rejects(client.call("error"), /Device unavailable/);
});
test("invalid helper output does not corrupt the next reply", async (t) => {
  const client = new NativeClient(process.execPath, [
    path.join(__dirname, "fixtures/helper.cjs"),
  ]);
  t.after(() => client.close());
  await once(client, "event");
  const notice = once(client, "notice");
  assert.deepEqual(await client.call("bad", { value: 7 }), { value: 7 });
  assert.match((await notice)[0], /invalid message/);
});
test("a crashed helper rejects pending work and clears its timers", async () => {
  const client = new NativeClient(process.execPath, [
    path.join(__dirname, "fixtures/helper.cjs"),
  ]);
  await once(client, "event");
  const pending = client.call("echo", { delay: 5000 });
  const exit = client.call("exit");
  const results = await Promise.allSettled([pending, exit]);
  assert.ok(results.every((result) => result.status === "rejected"));
  assert.equal(client.pending.size, 0);
  assert.equal(client.closed, true);
});
