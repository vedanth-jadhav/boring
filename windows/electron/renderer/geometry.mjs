// Exact critically damped integration: frame-rate independent, interruptible,
// and with continuous position and velocity when the target changes.
export class Spring {
  constructor(value, frequency = 28) {
    this.value = value;
    this.velocity = 0;
    this.target = value;
    this.frequency = frequency;
  }
  set(target, immediate = false) {
    this.target = target;
    if (immediate) {
      this.value = target;
      this.velocity = 0;
    }
  }
  step(seconds) {
    const dt = Math.max(0, Math.min(seconds, 0.1));
    const displacement = this.value - this.target;
    const impulse = this.velocity + this.frequency * displacement;
    const decay = Math.exp(-this.frequency * dt);
    this.value = this.target + (displacement + impulse * dt) * decay;
    this.velocity = (this.velocity - this.frequency * impulse * dt) * decay;
    if (
      Math.abs(this.value - this.target) < 0.05 &&
      Math.abs(this.velocity) < 0.5
    ) {
      this.value = this.target;
      this.velocity = 0;
    }
    return this.value;
  }
  get active() {
    return this.value !== this.target || this.velocity !== 0;
  }
}
export function notchPath(width, height, edge, radius = 24) {
  const w = Math.max(1, width),
    h = Math.max(1, height),
    r = Math.min(radius, h / 2);
  if (!edge)
    return `M${r},0H${w - r}Q${w},0 ${w},${r}V${h - r}Q${w},${h} ${w - r},${h}H${r}Q0,${h} 0,${h - r}V${r}Q0,0 ${r},0Z`;
  const t = Math.min(19, w / 8, h / 2),
    b = Math.min(32, h / 2, w / 8);
  return `M0,0H${w}Q${w - t},0 ${w - t},${t}V${h - b}Q${w - t},${h} ${w - t - b},${h}H${t + b}Q${t},${h} ${t},${h - b}V${t}Q${t},0 0,0Z`;
}
export function playbackPosition(media, now) {
  const delta = media.playing
    ? Math.max(
        0,
        (now - Date.parse(media.sampled || new Date(now).toISOString())) / 1000,
      ) * (media.rate ?? 1)
    : 0;
  return Math.max(
    0,
    Math.min(media.duration || Infinity, (media.position || 0) + delta),
  );
}
export function currentLine(lines, position, background = false) {
  let first = null,
    current = null;
  for (const line of lines || []) {
    if (!!line.isBackground !== background) continue;
    first ||= line;
    if (line.time <= position) current = line;
    else break;
  }
  current ||= first;
  if (
    background &&
    current &&
    (position < current.time ||
      position > (current.end ?? current.words?.at(-1)?.end ?? current.time))
  )
    return null;
  return current;
}
