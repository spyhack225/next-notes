/**
 * The Mac app's orb engine, ported line for line from
 * `Sources/NextNotes/UI/Components/ThinkingOrbs/OrbGeometry.swift`.
 *
 * Nine states, each a pure function of `(size, time)` returning finished draw
 * instructions — position, radius and opacity, already sorted back to front. The maths,
 * the tuned constants and the vendored preset tables are the app's, so an orb on this
 * page is the orb in the menu bar. Only the large (non-inline) tunings are carried over;
 * the site never draws the 20pt inline variant.
 *
 * Nothing here is random. The two states that scatter — `solving`'s scramble and
 * `connecting`'s packets — read a deterministic hash of an index, so the same instant
 * always yields the same frame, on this page as in the app.
 */

/** What an agent is doing, in the orb's vocabulary. */
export type OrbState =
  | "listening"
  | "working"
  | "composing"
  | "searching"
  | "solving"
  | "connecting"
  | "weaving"
  | "breathing"
  | "shaping";

/** One finished mark: where, how big, how heavily inked. */
export type Dot = { x: number; y: number; r: number; o: number };

/** One finished edge: a straight stroke between two projected points. */
export type Segment = {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  w: number;
  o: number;
};

/** One instant, complete: the edges to stroke first, then the dots to fill over them. */
export type Frame = { dots: Dot[]; segments: Segment[] };

/** Position, depth, radius and ink before the frame is finished. */
type Raw = { x: number; y: number; z: number; r: number; white: number; alpha: number };

type RawLine = {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  white: number;
  alpha: number;
  width: number;
};

// MARK: - Tuning

type Preset = {
  speed: number;
  rsPow: number;
  rMin: number;

  // orbits
  orbitN: number;
  ghostN: number;
  ghostR: number;
  ghostA: number;
  particles: number;
  partR: number;
  partRDepth: number;

  // sphere lattices (globe, wave, rubik)
  latRings: number;
  lonDensity: number;
  rBase: number;
  rDepth: number;
  rBoost: number;
  inkFar: number;
  inkSpan: number;
  scanMul: number;
  dimBase: number;
  moveCount: number;
  rActive: number;

  // ribbon (and ring, which is the same band seen face on)
  lanes: number;
  segs: number;
  bandMul: number;
  wobMul: number;
  spin: number;
  faceOn: boolean;

  // web
  nodeN: number;
  thr: number;
  signals: number;
  nodeR: number;
  nodeRDepth: number;
  lineW: number;
  /** How far the figure spreads inside its box. Read by `web` and by `morph`. */
  spread: number;

  // braid
  strandN: number;
  turns: number;

  // morph
  rDot: number;
  iconD: number;
};

/** The Swift struct's member-wise defaults, verbatim. */
const DEFAULTS: Omit<Preset, "speed"> = {
  rsPow: 0.6,
  rMin: 0.3,
  orbitN: 12,
  ghostN: 40,
  ghostR: 0.9,
  ghostA: 0.5,
  particles: 3,
  partR: 1.2,
  partRDepth: 1.6,
  latRings: 17,
  lonDensity: 44,
  rBase: 0.6,
  rDepth: 1.7,
  rBoost: 1.0,
  inkFar: 0.62,
  inkSpan: 0.54,
  scanMul: 1.0,
  dimBase: 1.0,
  moveCount: 14,
  rActive: 0.3,
  lanes: 5,
  segs: 88,
  bandMul: 1.0,
  wobMul: 1.0,
  spin: 1.0,
  faceOn: false,
  nodeN: 30,
  thr: 0.72,
  signals: 5,
  nodeR: 1.4,
  nodeRDepth: 1.8,
  lineW: 0.8,
  spread: 1.0,
  strandN: 52,
  turns: 3.0,
  rDot: 0.021,
  iconD: 1.0,
};

const mk = (over: Partial<Preset> & { speed: number }): Preset => ({
  ...DEFAULTS,
  ...over,
});

/**
 * The upstream presets resolved at the large size. These are vendored data, not view
 * constants — the same literals the Swift carries.
 */
const PRESETS: Record<OrbState, Preset> = {
  working: mk({ speed: 1.885 }),
  searching: mk({
    speed: 2.015,
    latRings: 11,
    lonDensity: 29,
    rBase: 0.69,
    rDepth: 1.955,
    rBoost: 1.15,
    scanMul: 4.08,
    dimBase: 0.45,
  }),
  listening: mk({ speed: 4.388, latRings: 9, lonDensity: 23 }),
  composing: mk({
    speed: 2.34,
    ghostN: 38,
    rBase: 0.935,
    rDepth: 1.445,
    lanes: 3,
    segs: 44,
    bandMul: 3.9,
    spin: 0,
  }),
  solving: mk({
    speed: 1.82,
    latRings: 9,
    lonDensity: 24,
    rBase: 0.63,
    rDepth: 1.785,
    moveCount: 14,
    rActive: 0.315,
  }),
  connecting: mk({
    speed: 3.315,
    nodeN: 41,
    signals: 7,
    nodeR: 1.33,
    nodeRDepth: 1.71,
  }),
  weaving: mk({ speed: 1.625, ghostN: 75, rBase: 1.2, rDepth: 1.8, strandN: 26 }),
  breathing: mk({
    speed: 3.24,
    ghostN: 0,
    rBase: 1.0516,
    rDepth: 1.6252,
    lanes: 3,
    segs: 44,
    bandMul: 3.627,
    wobMul: 0.368,
    spin: 0,
    faceOn: true,
  }),
  shaping: mk({
    speed: 2.405,
    rMin: 0.25,
    spread: 1.45,
    rDot: 0.008295,
    iconD: 0.702,
  }),
};

/** Each state runs at its own tempo. The shell reads this to drive the clock. */
export const orbSpeed = (state: OrbState): number => PRESETS[state].speed;

// MARK: - Shared primitives

/** Spin, tilt and an orthographic projection, precomputed once per frame. */
type Project = (x: number, y: number, z: number) => { x: number; y: number; z: number };

function projection(
  yaw: number,
  tilt: number,
  cx: number,
  cy: number,
  scale: number,
): Project {
  const cosYaw = Math.cos(yaw);
  const sinYaw = Math.sin(yaw);
  const cosTilt = Math.cos(tilt);
  const sinTilt = Math.sin(tilt);
  return (x, y, z) => {
    const x1 = x * cosYaw + z * sinYaw;
    const z1 = -x * sinYaw + z * cosYaw;
    const y1 = y * cosTilt - z1 * sinTilt;
    const z2 = y * sinTilt + z1 * cosTilt;
    // `z` is deliberately left unscaled: every depth term downstream divides by whatever
    // radius that mode kept the point in, exactly as the Swift does.
    return { x: cx + x1 * scale, y: cy - y1 * scale, z: z2 };
  };
}

/** Deterministic hash in 0..<1. */
function hash(a: number, b: number): number {
  const h = Math.sin(a * 12.9898 + b * 78.233) * 43758.5453;
  return h - Math.floor(h);
}

/** The fractional part, matching the original's `frac`. */
const fract = (x: number) => x - Math.floor(x);

/** Value noise on a 2D lattice — smooth, deterministic, cheap. */
function valueNoise(x: number, y: number): number {
  const xi = Math.floor(x);
  const yi = Math.floor(y);
  let fx = x - xi;
  let fy = y - yi;
  fx = fx * fx * (3 - 2 * fx);
  fy = fy * fy * (3 - 2 * fy);
  const a = hash(xi, yi);
  const b = hash(xi + 1, yi);
  const c = hash(xi, yi + 1);
  const d = hash(xi + 1, yi + 1);
  return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
}

/** Stable directions on a unit sphere. */
function fibonacciDirection(i: number, n: number): [number, number, number] {
  const golden = Math.PI * (3 - Math.sqrt(5));
  const y = 1 - (2 * (i + 0.5)) / n;
  const rad = Math.sqrt(Math.max(0, 1 - y * y));
  const a = i * golden;
  return [rad * Math.cos(a), y, rad * Math.sin(a)];
}

/** Shortest signed angular distance, wrapped to (-pi, pi]. */
const angleDelta = (a: number, b: number) => Math.atan2(Math.sin(a - b), Math.cos(a - b));

/**
 * Radii were tuned for a 300pt frame; the sub-linear falloff is what keeps a small orb
 * legible instead of dissolving into dust.
 */
const radiusScale = (size: number, exponent: number) => Math.pow(size / 300, exponent);

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

/** Drop invisible marks, clamp radii to the mode's floor, sort far to near. */
function finalizeDots(raw: Raw[], rMin: number): Dot[] {
  return raw
    .filter((d) => d.alpha >= 0.02)
    .sort((a, b) => a.z - b.z)
    .map((d) => ({
      x: d.x,
      y: d.y,
      r: Math.max(rMin, d.r),
      // The upstream ink value mirrors on a dark substrate. One minus the ink is the
      // weight of the mark; the page decides what colour that weight is.
      o: clamp01((1 - clamp01(d.white)) * d.alpha),
    }));
}

/** Drop invisible edges and invert the ink, exactly as `finalizeDots` does. */
function finalizeLines(raw: RawLine[]): Segment[] {
  return raw
    .filter((l) => l.alpha >= 0.02)
    .map((l) => ({
      x1: l.x1,
      y1: l.y1,
      x2: l.x2,
      y2: l.y2,
      w: l.width,
      o: clamp01((1 - clamp01(l.white)) * l.alpha),
    }));
}

// MARK: - Modes

/**
 * Particles on tilted orbits — `working`. No nucleus: the tuned preset runs coreless, so
 * what you see is ghost paths and the particles doing the work.
 */
function orbits(size: number, t: number, o: Preset): Raw[] {
  const centre = size / 2;
  const radius = (size / 2) * 0.82;
  const project = projection(t * 0.12, 0.3, centre, centre, 1);
  const rs = radiusScale(size, o.rsPow);
  const dots: Raw[] = [];

  for (let orb = 0; orb < o.orbitN; orb++) {
    const h1 = hash(orb, 1.7);
    const h2 = hash(orb, 5.2);
    const h3 = hash(orb, 8.9);
    const ro = radius * (0.45 + 0.52 * h1);
    const theta = h1 * 2 * Math.PI;
    const phi = Math.acos(2 * h2 - 1);

    // The orbit plane, as two perpendicular unit vectors in it.
    const nx = Math.sin(phi) * Math.cos(theta);
    const ny = Math.cos(phi);
    const nz = Math.sin(phi) * Math.sin(theta);
    let ux = -ny;
    let uy = nx;
    const uz = 0;
    const ul = Math.max(1e-6, Math.sqrt(ux * ux + uy * uy));
    ux /= ul;
    uy /= ul;
    const vx = ny * uz - nz * uy;
    const vy = nz * ux - nx * uz;
    const vz = nx * uy - ny * ux;
    const speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1);

    for (let k = 0; k < o.ghostN; k++) {
      const a = (k / o.ghostN) * 2 * Math.PI;
      const ca = Math.cos(a);
      const sa = Math.sin(a);
      const p = project((ux * ca + vx * sa) * ro, (uy * ca + vy * sa) * ro, (uz * ca + vz * sa) * ro);
      const depth = (p.z / ro + 1) / 2;
      dots.push({
        x: p.x,
        y: p.y,
        z: p.z,
        r: o.ghostR * rs,
        white: 0.72,
        alpha: o.ghostA * (0.4 + 0.6 * depth),
      });
    }

    for (let m = 0; m < o.particles; m++) {
      const a = t * speed + (m / o.particles) * 2 * Math.PI + h2 * 6;
      const ca = Math.cos(a);
      const sa = Math.sin(a);
      const p = project((ux * ca + vx * sa) * ro, (uy * ca + vy * sa) * ro, (uz * ca + vz * sa) * ro);
      const depth = (p.z / ro + 1) / 2;
      dots.push({
        x: p.x,
        y: p.y,
        z: p.z,
        r: (o.partR + o.partRDepth * depth) * rs,
        white: 0.3 - 0.22 * depth,
        alpha: 1,
      });
    }
  }
  return dots;
}

/**
 * A lat/long field with a scan meridian sweeping through it — `searching`. The scan is
 * read as a size ripple rather than a highlight, because there is only one ink.
 */
function globe(size: number, t: number, o: Preset): Raw[] {
  const spin = 0.5;
  const centre = size / 2;
  const radius = (size / 2) * 0.82;
  const tilt = 0.4 + 0.06 * Math.sin(t * 0.35);
  const project = projection(t * spin, tilt, centre, centre, radius);
  const scan = t * (spin + (1.7 - spin) * o.scanMul);
  const rs = radiusScale(size, o.rsPow);

  const dots: Raw[] = [];
  for (let li = 0; li <= o.latRings; li++) {
    const lat = -Math.PI / 2 + (li / o.latRings) * Math.PI;
    const cosLat = Math.cos(lat);
    const sinLat = Math.sin(lat);
    const lonCount = Math.max(1, Math.round(Math.abs(cosLat) * o.lonDensity));
    for (let lj = 0; lj < lonCount; lj++) {
      const lon = (lj / lonCount) * 2 * Math.PI;
      const p = project(cosLat * Math.cos(lon), sinLat, cosLat * Math.sin(lon));
      const depth = (p.z + 1) / 2;
      const d = angleDelta(lon + t * spin, scan);
      const boost = Math.exp(-(d * d) / 0.18) * Math.max(0, p.z);
      dots.push({
        x: p.x,
        y: p.y,
        z: p.z,
        r: (o.rBase + o.rDepth * depth + o.rBoost * boost) * rs,
        white: o.inkFar - o.inkSpan * depth,
        alpha: o.dimBase + (1 - o.dimBase) * Math.min(1, boost),
      });
    }
  }
  return dots;
}

/**
 * A waveform rolling through the rings — `listening`. Two waves at different tempi, so it
 * never quite repeats.
 */
function wave(size: number, t: number, o: Preset): Raw[] {
  const centre = size / 2;
  // 0.76 x 1.15: the undulation pulls the sphere inward, so this mode reads smaller than
  // the other lattices unless it is scaled back up to match them.
  const radius = (size / 2) * 0.874;
  const project = projection(t * 0.18, 0.38, centre, centre, 1);
  const rs = radiusScale(size, o.rsPow);

  const dots: Raw[] = [];
  for (let ri = 0; ri <= o.latRings; ri++) {
    const lat = -Math.PI / 2 + (ri / o.latRings) * Math.PI;
    const cosLat = Math.cos(lat);
    const sinLat = Math.sin(lat);
    const w = 0.62 * Math.sin(t * 2.1 - ri * 0.52) + 0.38 * Math.sin(t * 1.27 + ri * 0.83);
    const rr = radius * (0.88 + 0.105 * w);
    const lonCount = Math.max(1, Math.round(Math.abs(cosLat) * o.lonDensity));
    for (let lj = 0; lj < lonCount; lj++) {
      const lon = (lj / lonCount) * 2 * Math.PI;
      const p = project(cosLat * Math.cos(lon) * rr, sinLat * rr, cosLat * Math.sin(lon) * rr);
      const depth = (p.z / radius + 1) / 2;
      const crest = Math.max(0, w);
      dots.push({
        x: p.x,
        y: p.y,
        z: p.z,
        r: (o.rBase + o.rDepth * depth) * (1 + 0.4 * crest) * rs,
        white: 0.66 - 0.56 * depth - 0.1 * crest,
        alpha: 1,
      });
    }
  }
  return dots;
}

/**
 * An undulating sash of parallel strands riding a great circle — `composing`. The tuned
 * preset freezes the tumble (`spin === 0`), leaving the travelling wave.
 *
 * The same geometry is also `breathing`, through `faceOn`: the band's plane is tilted back
 * by exactly the camera's own tilt so the great circle projects as a true circle rather
 * than an ellipse, and the undulation moves onto the in-plane *radius*. That second move
 * is the one that matters — a wobble along the plane normal is undone by the
 * re-normalisation below, so the silhouette would be pinned at `radius` and the
 * deformation could only ever pull dots inward.
 */
function ribbon(size: number, t: number, o: Preset): Raw[] {
  const centre = size / 2;
  const radius = (size / 2) * 0.78;
  const camTilt = 0.3;
  const project = projection(t * 0.1 * o.spin, camTilt, centre, centre, 1);
  const rs = radiusScale(size, o.rsPow);

  const dots: Raw[] = [];
  for (let i = 0; i < o.ghostN; i++) {
    const d = fibonacciDirection(i, o.ghostN);
    const p = project(d[0] * radius, d[1] * radius, d[2] * radius);
    const depth = (p.z / radius + 1) / 2;
    dots.push({
      x: p.x,
      y: p.y,
      z: p.z,
      r: 0.8 * rs,
      white: 0.78,
      alpha: 0.1 + 0.22 * depth,
    });
  }

  const ya = t * 0.24 * o.spin;
  const ta = o.faceOn ? -camTilt : 0.55 + 0.3 * Math.sin(t * 0.18) * o.spin;
  const ux = Math.cos(ya);
  const uy = 0;
  const uz = Math.sin(ya);
  const vx = -uz * Math.sin(ta);
  const vy = Math.cos(ta);
  const vz = ux * Math.sin(ta);
  const nx = uy * vz - uz * vy;
  const ny = uz * vx - ux * vz;
  const nz = ux * vy - uy * vx;

  // Radial lobes swell past `radius`, so a face-on band pulls its base radius in by most
  // of the wobble amplitude: the silhouette then stays inside the frame however far the
  // deformation is pushed.
  const wobAmp = 0.23 * o.wobMul;
  const baseR = o.faceOn ? radius / (1 + 0.85 * wobAmp) : radius;

  const lanes = Math.max(1, Math.round(o.lanes * o.bandMul));
  for (let w = 0; w < lanes; w++) {
    const laneOff = (w - (lanes - 1) / 2) * 0.075;
    const edge = Math.abs(w - (lanes - 1) / 2) / Math.max(1, (lanes - 1) / 2);
    for (let k = 0; k < o.segs; k++) {
      const a = (k / o.segs) * 2 * Math.PI;
      const wob =
        (0.16 * Math.sin(a * 3 - t * 1.7 + w * 0.22) + 0.07 * Math.sin(a * 5 + t * 1.1)) *
        o.wobMul;
      const radial = o.faceOn ? 1 + wob : 1;
      const off = o.faceOn ? laneOff : laneOff + wob;
      const ca = Math.cos(a);
      const sa = Math.sin(a);
      const x = ux * ca + vx * sa + nx * off;
      const y = uy * ca + vy * sa + ny * off;
      const z = uz * ca + vz * sa + nz * off;
      const l = Math.sqrt(x * x + y * y + z * z);
      const rr = baseR * radial;
      const p = project((x / l) * rr, (y / l) * rr, (z / l) * rr);
      const depth = (p.z / radius + 1) / 2;
      dots.push({
        x: p.x,
        y: p.y,
        z: p.z,
        r: (o.rBase + o.rDepth * depth) * (1 - 0.25 * edge) * rs,
        white: 0.52 - 0.44 * depth + 0.18 * edge,
        alpha: 0.4 + 0.6 * depth,
      });
    }
  }
  return dots;
}

// MARK: - The solver (`solving`)

/** One quarter turn of a slab of the sphere. */
type Twist = { axis: number; lo: number; hi: number; angle: number };

/** How far through each move the solver has got, and which one its hand is on. */
type SolveCycle = { amount: number[]; hand: number };

/**
 * The scramble. Drawn from the deterministic hash rather than a generator, so every run
 * scrambles the same sphere the same way.
 */
function twists(count: number): Twist[] {
  const out: Twist[] = [];
  for (let i = 0; i < count; i++) {
    const axis = Math.min(2, Math.floor(hash(i, 2.3) * 3));
    const slab = Math.min(3, Math.floor(hash(i, 5.9) * 4));
    const lo = -1 + 0.5 * slab;
    const direction = hash(i, 7.7) < 0.5 ? 1 : -1;
    out.push({ axis, lo, hi: lo + 0.5, angle: (direction * Math.PI) / 2 });
  }
  return out;
}

/**
 * Moves land one after another on a machine ease-out, then play back in reverse — a
 * palindrome, so the sphere is always solved again before it rests.
 */
function solveCycle(t: number, count: number, slot: number, rest: number): SolveCycle {
  const span = 2 * count * slot;
  const tc = t % (span + rest);
  const amount = new Array<number>(count).fill(0);
  let hand = -1;
  if (tc < span) {
    const index = Math.min(2 * count - 1, Math.floor(tc / slot));
    const p = (tc - index * slot) / slot;
    const eased = 1 - Math.pow(1 - Math.min(1, p / 0.7), 3);
    if (index < count) {
      for (let i = 0; i < index; i++) amount[i] = 1;
      amount[index] = eased;
      hand = index;
    } else {
      const undo = 2 * count - 1 - index;
      for (let i = 0; i < undo; i++) amount[i] = 1;
      amount[undo] = 1 - eased;
      hand = undo;
    }
  }
  return { amount, hand };
}

/** Turn one point by whichever moves currently have it in their slab. */
function applyTwists(
  px: number,
  py: number,
  pz: number,
  moves: Twist[],
  cycle: SolveCycle,
): { x: number; y: number; z: number; inHand: boolean } {
  let x = px;
  let y = py;
  let z = pz;
  let inHand = false;
  for (let i = 0; i < moves.length; i++) {
    const move = moves[i];
    const amount = cycle.amount[i];
    if (amount <= 0) continue;
    const coord = move.axis === 0 ? x : move.axis === 1 ? y : z;
    if (coord < move.lo || coord >= move.hi) continue;
    if (i === cycle.hand) inHand = true;
    const a = move.angle * amount;
    const ca = Math.cos(a);
    const sa = Math.sin(a);
    if (move.axis === 0) {
      const y2 = y * ca - z * sa;
      z = y * sa + z * ca;
      y = y2;
    } else if (move.axis === 1) {
      const x2 = x * ca + z * sa;
      z = -x * sa + z * ca;
      x = x2;
    } else {
      const x2 = x * ca - y * sa;
      y = x * sa + y * ca;
      x = x2;
    }
  }
  return { x, y, z, inHand };
}

/**
 * A lattice whose bands twist in quarter turns — `solving`. Rapid eased moves scramble the
 * sphere, then replay in reverse, so it always clicks back to solved before it rests and
 * starts again. The band under the hand inks a touch darker.
 */
function rubik(size: number, t: number, o: Preset): Raw[] {
  const centre = size / 2;
  const radius = (size / 2) * 0.82;
  const project = projection(
    t * 0.55,
    0.35 + 0.1 * Math.sin(t * 0.9),
    centre,
    centre,
    radius,
  );
  const rs = radiusScale(size, o.rsPow);
  const moves = twists(o.moveCount);
  const cycle = solveCycle(t, o.moveCount, 0.42, 1.2);

  const dots: Raw[] = [];
  for (let li = 0; li <= o.latRings; li++) {
    const lat = -Math.PI / 2 + (li / o.latRings) * Math.PI;
    const cosLat = Math.cos(lat);
    const sinLat = Math.sin(lat);
    const lonCount = Math.max(1, Math.round(Math.abs(cosLat) * o.lonDensity));
    for (let lj = 0; lj < lonCount; lj++) {
      const lon = (lj / lonCount) * 2 * Math.PI;
      const turned = applyTwists(
        cosLat * Math.cos(lon),
        sinLat,
        cosLat * Math.sin(lon),
        moves,
        cycle,
      );
      const p = project(turned.x, turned.y, turned.z);
      const depth = (p.z + 1) / 2;
      dots.push({
        x: p.x,
        y: p.y,
        z: p.z,
        r: (o.rBase + o.rDepth * depth + (turned.inHand ? o.rActive : 0)) * rs,
        white: o.inkFar - o.inkSpan * depth - (turned.inHand ? 0.14 : 0),
        alpha: 1,
      });
    }
  }
  return dots;
}

/**
 * A constellation wiring itself — `connecting`. Nodes drift over the sphere under slow
 * value noise, any pair closer than `thr` grows an edge, and bright packets run between
 * pairs the clock re-picks every couple of seconds.
 *
 * The only mode that returns edges as well as dots. Without the wires it is a sphere of
 * drifting points, which is `working` with the orbits taken away. The wires are the state.
 */
function web(size: number, t: number, o: Preset): { dots: Raw[]; lines: RawLine[] } {
  const centre = size / 2;
  const radius = (size / 2) * 0.8 * o.spread;
  // The projection carries the radius as its scale, so the node vectors stay unit length
  // and the proximity test below is in unit-sphere space.
  const project = projection(t * 0.12, 0.32, centre, centre, radius);
  const rs = radiusScale(size, o.rsPow);

  const nodes: { x: number; y: number; z: number }[] = [];
  for (let i = 0; i < o.nodeN; i++) {
    const d = fibonacciDirection(i, o.nodeN);
    const x = d[0] + 0.3 * (valueNoise(i * 0.31 + 9, t * 0.24) - 0.5) * 2;
    const y = d[1] + 0.3 * (valueNoise(i * 0.53 + 27, t * 0.21) - 0.5) * 2;
    const z = d[2] + 0.3 * (valueNoise(i * 0.77 + 55, t * 0.27) - 0.5) * 2;
    const l = Math.max(1e-6, Math.sqrt(x * x + y * y + z * z));
    nodes.push({ x: x / l, y: y / l, z: z / l });
  }

  const lines: RawLine[] = [];
  const width = Math.max(0.6, o.lineW * rs);
  for (let i = 0; i < o.nodeN; i++) {
    for (let j = i + 1; j < o.nodeN; j++) {
      const dx = nodes[i].x - nodes[j].x;
      const dy = nodes[i].y - nodes[j].y;
      const dz = nodes[i].z - nodes[j].z;
      const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dist >= o.thr) continue;
      const a = project(nodes[i].x, nodes[i].y, nodes[i].z);
      const b = project(nodes[j].x, nodes[j].y, nodes[j].z);
      const depth = ((a.z + b.z) / 2 + 1) / 2;
      lines.push({
        x1: a.x,
        y1: a.y,
        x2: b.x,
        y2: b.y,
        white: 0.42,
        alpha: (1 - dist / o.thr) * (0.3 + 0.55 * depth),
        width,
      });
    }
  }

  const dots: Raw[] = [];
  for (let i = 0; i < o.nodeN; i++) {
    const p = project(nodes[i].x, nodes[i].y, nodes[i].z);
    const depth = (p.z + 1) / 2;
    const pulse = 1 + 0.25 * Math.sin(t * 1.4 + i * 2.7);
    dots.push({
      x: p.x,
      y: p.y,
      z: p.z,
      r: (o.nodeR + o.nodeRDepth * depth) * pulse * rs,
      white: 0.55 - 0.45 * depth,
      alpha: 1,
    });
  }

  // The packets. Which pair each one runs between is a hash of the segment index, so the
  // sequence is fixed rather than random — the same instant always wires the same two
  // nodes.
  for (let s = 0; s < o.signals; s++) {
    const travel = t * 0.55 + s * 7.31;
    const leg = Math.floor(travel);
    const a = Math.min(o.nodeN - 1, Math.trunc(hash(leg, s * 3.1 + 1.7) * o.nodeN));
    const b = Math.min(o.nodeN - 1, Math.trunc(hash(leg, s * 5.7 + 4.2) * o.nodeN));
    if (a === b) continue;
    const f = travel - leg;
    const x = nodes[a].x + (nodes[b].x - nodes[a].x) * f;
    const y = nodes[a].y + (nodes[b].y - nodes[a].y) * f;
    const z = nodes[a].z + (nodes[b].z - nodes[a].z) * f;
    const l = Math.max(1e-6, Math.sqrt(x * x + y * y + z * z));
    const p = project(x / l, y / l, z / l);
    const depth = (p.z + 1) / 2;
    dots.push({
      x: p.x,
      y: p.y,
      z: p.z,
      r: (o.nodeR * 1.5 + o.nodeRDepth * depth) * rs,
      white: 0.05,
      alpha: 0.5 + 0.5 * depth,
    });
  }

  return { dots, lines };
}

/**
 * Three strands plaiting around the sphere — `weaving`. Each runs pole to pole on a helix;
 * a radial breathing term makes them trade places, and that trade is what reads as the
 * over and under of a plait.
 */
function braid(size: number, t: number, o: Preset): Raw[] {
  const centre = size / 2;
  const radius = (size / 2) * 0.76;
  const project = projection(t * 0.4, 0.3, centre, centre, 1);
  const rs = radiusScale(size, o.rsPow);

  const dots: Raw[] = [];
  for (let i = 0; i < o.ghostN; i++) {
    const d = fibonacciDirection(i, o.ghostN);
    const p = project(d[0] * radius, d[1] * radius, d[2] * radius);
    const depth = (p.z / radius + 1) / 2;
    dots.push({
      x: p.x,
      y: p.y,
      z: p.z,
      r: 0.8 * rs,
      white: 0.78,
      alpha: 0.1 + 0.22 * depth,
    });
  }

  for (let s = 0; s < 3; s++) {
    const phase = (s / 3) * 2 * Math.PI;
    for (let i = 0; i < o.strandN; i++) {
      // `u` walks pole to pole; the fractional drift slides the whole strand along.
      const u = (fract(i / o.strandN + t * 0.045) * 2 - 1) * 0.96;
      const surf = Math.sqrt(Math.max(0, 1 - u * u));
      const endFade = Math.min(1, (1 - Math.abs(u)) / 0.1);
      const a = u * Math.PI * o.turns + phase;
      const weave = 1 + 0.075 * Math.sin(u * Math.PI * o.turns * 2 + phase * 2 + t * 0.8);
      const rr = surf * radius * weave;
      const p = project(Math.cos(a) * rr, u * radius * weave, Math.sin(a) * rr);
      const depth = (p.z / radius + 1) / 2;
      dots.push({
        x: p.x,
        y: p.y,
        z: p.z,
        r: (o.rBase + o.rDepth * depth) * rs,
        white: 0.55 - 0.45 * depth,
        alpha: endFade * (0.45 + 0.55 * depth),
      });
    }
  }
  return dots;
}

// MARK: - The outline (`shaping`)

/** A closed polygon sampled by arc-length fraction. */
function polygonPoint(verts: [number, number][], f: number): [number, number] {
  const count = verts.length;
  const lengths: number[] = [];
  let total = 0;
  for (let i = 0; i < count; i++) {
    const a = verts[i];
    const b = verts[(i + 1) % count];
    const l = Math.sqrt((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2);
    lengths.push(l);
    total += l;
  }
  let target = f * total;
  let i = 0;
  while (target > lengths[i] && i < count - 1) {
    target -= lengths[i];
    i += 1;
  }
  const a = verts[i];
  const b = verts[(i + 1) % count];
  const ff = lengths[i] !== 0 ? Math.min(1, target / lengths[i]) : 0;
  return [a[0] + (b[0] - a[0]) * ff, a[1] + (b[1] - a[1]) * ff];
}

/**
 * One of the three morph targets, sampled by arc-length fraction. All three start at top
 * centre and run clockwise, which is what lets two of them be blended point by point
 * without the outline turning itself inside out.
 */
function morphShape(index: number, f: number): [number, number] {
  if (index === 0) {
    const a = -Math.PI / 2 + f * 2 * Math.PI;
    return [Math.cos(a) * 0.24, Math.sin(a) * 0.24];
  }
  if (index === 1) {
    return polygonPoint(
      [
        [0, -0.26],
        [0.24, 0.16],
        [-0.24, 0.16],
      ],
      f,
    );
  }
  // Five vertices rather than four, so the walk starts at top centre like the other two
  // rather than at a corner.
  return polygonPoint(
    [
      [0, -0.2],
      [0.2, -0.2],
      [0.2, 0.2],
      [-0.2, 0.2],
      [-0.2, -0.2],
    ],
    f,
  );
}

/**
 * A dotted outline cycling circle -> triangle -> square -> circle — `shaping`. The only
 * flat mode: every dot sits at `z === 0` and depth plays no part.
 *
 * Every frame blends the two neighbouring paths, measures the result, and lays the dots
 * *evenly* along it — so the spacing stays uniform at every instant of the morph, holds
 * and transitions alike, rather than bunching at the corners.
 */
function morph(size: number, t: number, o: Preset): Raw[] {
  const shapes = 3;
  const hold = 1.4;
  const travel = 0.9;
  const leg = hold + travel;
  const tc = t % (leg * shapes);
  const k = Math.min(shapes - 1, Math.floor(tc / leg));
  const local = tc - k * leg;
  // Smoothstep, so a shape leaves and arrives at rest rather than snapping.
  let m = 0;
  if (local > hold) {
    const x = (local - hold) / travel;
    m = x * x * (3 - 2 * x);
  }

  // Blend the two shape paths, then measure the blended outline.
  const samples = 160;
  const pts: [number, number][] = [];
  for (let i = 0; i < samples; i++) {
    const f = i / samples;
    const a = morphShape(k, f);
    const b = morphShape((k + 1) % shapes, f);
    pts.push([
      (a[0] + (b[0] - a[0]) * m) * o.spread,
      (a[1] + (b[1] - a[1]) * m) * o.spread,
    ]);
  }
  const lengths: number[] = [];
  let total = 0;
  for (let i = 0; i < samples; i++) {
    const a = pts[i];
    const b = pts[(i + 1) % samples];
    const l = Math.sqrt((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2);
    lengths.push(l);
    total += l;
  }

  // The radius depends only on `rDot`; the count is what sets the gaps. A formed shape
  // breathes a little on the spot.
  const n = Math.max(6, Math.round(34 * o.iconD));
  const re = o.rDot * 1.35 * o.spread;
  const pulse = 1 + 0.02 * Math.sin(local * 3.1);

  const dots: Raw[] = [];
  const centre = size / 2;
  let seg = 0;
  let acc = 0;
  for (let step = 0; step < n; step++) {
    const target = (step / n) * total;
    while (acc + lengths[seg] < target && seg < samples - 1) {
      acc += lengths[seg];
      seg += 1;
    }
    const a = pts[seg];
    const b = pts[(seg + 1) % samples];
    const f = lengths[seg] !== 0 ? Math.min(1, (target - acc) / lengths[seg]) : 0;
    const x = (a[0] + (b[0] - a[0]) * f) * pulse;
    const y = (a[1] + (b[1] - a[1]) * f) * pulse;
    dots.push({
      x: centre + x * size,
      y: centre + y * size,
      z: 0,
      r: Math.max(0.35, re * size),
      white: 0.1,
      alpha: 1,
    });
  }
  return dots;
}

// MARK: - Entry point

/**
 * Everything one instant draws: edges and dots, both finished. `time` is in seconds; the
 * state's own preset speed is applied here, exactly as the Swift does.
 */
export function orbFrame(state: OrbState, size: number, time: number): Frame {
  const o = PRESETS[state];
  const t = time * o.speed;
  let raw: Raw[];
  let lines: RawLine[] = [];
  switch (state) {
    case "working":
      raw = orbits(size, t, o);
      break;
    case "searching":
      raw = globe(size, t, o);
      break;
    case "listening":
      raw = wave(size, t, o);
      break;
    // `breathing` is `composing`'s geometry seen face on — see `ribbon`.
    case "composing":
    case "breathing":
      raw = ribbon(size, t, o);
      break;
    case "solving":
      raw = rubik(size, t, o);
      break;
    case "weaving":
      raw = braid(size, t, o);
      break;
    case "shaping":
      raw = morph(size, t, o);
      break;
    case "connecting": {
      const built = web(size, t, o);
      raw = built.dots;
      lines = built.lines;
      break;
    }
  }
  return { dots: finalizeDots(raw, o.rMin), segments: finalizeLines(lines) };
}
