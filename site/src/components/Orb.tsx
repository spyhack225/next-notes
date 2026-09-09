import { useEffect, useRef } from "react";

/**
 * The Speechify mark: the app's own `listening` orb, a waveform rolling through the
 * latitude rings of a dotted sphere. The geometry and the preset below are ported from
 * the Mac app's OrbGeometry, so the sphere on this page is the sphere in the menu bar.
 *
 * There is no stock imagery anywhere on this site. Every place a landing page would
 * normally put a background video, this component goes instead.
 */
const P = {
  speed: 4.388,
  latRings: 9,
  lonDensity: 23,
  rBase: 0.6,
  rDepth: 1.7,
  rsPow: 0.6,
  rMin: 0.3,
};

/** The frame the app freezes on when the system asks for less motion. */
const STILL_T = 1.7 * P.speed;

type Dot = { x: number; y: number; z: number; r: number; o: number };

function drawOrb(ctx: CanvasRenderingContext2D, size: number, t: number) {
  const c = size / 2;
  const radius = (size / 2) * 0.874;
  const yaw = t * 0.18;
  const tilt = 0.38;
  const cy = Math.cos(yaw);
  const sy = Math.sin(yaw);
  const ct = Math.cos(tilt);
  const st = Math.sin(tilt);
  const rs = Math.pow(size / 300, P.rsPow);
  const dots: Dot[] = [];

  for (let ri = 0; ri <= P.latRings; ri++) {
    const lat = -Math.PI / 2 + (ri / P.latRings) * Math.PI;
    const cosLat = Math.cos(lat);
    const sinLat = Math.sin(lat);
    const w =
      0.62 * Math.sin(t * 2.1 - ri * 0.52) + 0.38 * Math.sin(t * 1.27 + ri * 0.83);
    const rr = radius * (0.88 + 0.105 * w);
    const lon = Math.max(1, Math.round(Math.abs(cosLat) * P.lonDensity));

    for (let lj = 0; lj < lon; lj++) {
      const a = (lj / lon) * 2 * Math.PI;
      const x = cosLat * Math.cos(a) * rr;
      const y = sinLat * rr;
      const z = cosLat * Math.sin(a) * rr;
      const x1 = x * cy + z * sy;
      const z1 = -x * sy + z * cy;
      const y1 = y * ct - z1 * st;
      const z2 = y * st + z1 * ct;
      const depth = (z2 / radius + 1) / 2;
      const crest = Math.max(0, w);
      const r = Math.max(P.rMin, (P.rBase + P.rDepth * depth) * (1 + 0.4 * crest) * rs);
      // Upstream's ink mirrors on a dark ground: one minus the value is the mark's weight.
      const o = Math.min(
        1,
        Math.max(0, 1 - Math.min(1, Math.max(0, 0.66 - 0.56 * depth - 0.1 * crest))),
      );
      dots.push({ x: c + x1, y: c - y1, z: z2, r, o });
    }
  }

  dots.sort((a, b) => a.z - b.z);

  ctx.clearRect(0, 0, size, size);
  ctx.fillStyle = "#ffffff";
  for (const d of dots) {
    ctx.globalAlpha = d.o;
    ctx.beginPath();
    ctx.arc(d.x, d.y, d.r, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;
}

export type OrbProps = {
  size: number;
  className?: string;
  /** Announced to screen readers; omit for the decorative background orbs. */
  label?: string;
};

export default function Orb({ size, className, label }: OrbProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = size * dpr;
    canvas.height = size * dpr;
    canvas.style.width = `${size}px`;
    canvas.style.height = `${size}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    let frame = 0;

    const run = () => {
      cancelAnimationFrame(frame);
      if (query.matches) {
        drawOrb(ctx, size, STILL_T);
        return;
      }
      const start = performance.now();
      const loop = (now: number) => {
        drawOrb(ctx, size, ((now - start) / 1000) * P.speed);
        frame = requestAnimationFrame(loop);
      };
      frame = requestAnimationFrame(loop);
    };

    run();
    query.addEventListener("change", run);

    return () => {
      cancelAnimationFrame(frame);
      query.removeEventListener("change", run);
    };
  }, [size]);

  return (
    <canvas
      ref={canvasRef}
      className={className}
      role={label ? "img" : "presentation"}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      style={{ display: "block", width: size, height: size }}
    />
  );
}
