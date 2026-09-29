import { useEffect, useRef, type CSSProperties } from "react";
import { orbFrame, type OrbState } from "./orbGeometry";
import { subscribeTheme } from "../lib/theme";

/**
 * The Next Notes mark: the app's own thinking orbs, all nine of them. The geometry lives in
 * `orbGeometry.ts`, ported from the Mac app's `OrbGeometry.swift`, so a state on this page
 * is the same state in the menu bar — same formulas, same tuned constants, same tempo.
 *
 * This file is only the shell: a canvas sized for the display, a rAF clock, and the
 * reduced-motion still. There is no stock imagery anywhere on this site; every place a
 * landing page would normally put a background video, this component goes instead.
 */

/**
 * The instant the app freezes on when the system asks for less motion, in seconds. Chosen
 * because it reads as a diagram of the state rather than motion caught mid-frame, and it
 * does that for all nine — each state scales this by its own preset speed.
 */
const STILL_TIME = 1.7;

/** The one ink. Depth is carried by radius and opacity alone; the hue follows the theme. */
const FALLBACK_INK = "#ffffff";

/**
 * A canvas cannot read a CSS variable, so the ink is resolved through a one-off probe
 * element: `getComputedStyle` hands back an `rgb()` every canvas understands, whichever
 * theme `--orb-ink` currently spells.
 */
function resolveInk(): string {
  const probe = document.createElement("span");
  probe.style.color = "hsl(var(--orb-ink))";
  probe.style.display = "none";
  document.body.appendChild(probe);
  const ink = getComputedStyle(probe).color;
  probe.remove();
  return ink || FALLBACK_INK;
}

function paint(
  ctx: CanvasRenderingContext2D,
  size: number,
  state: OrbState,
  time: number,
  ink: string,
) {
  const { dots, segments } = orbFrame(state, size, time);

  ctx.clearRect(0, 0, size, size);

  // Edges first, under every dot — `connecting` is the only state that has any.
  if (segments.length > 0) {
    ctx.strokeStyle = ink;
    ctx.lineCap = "round";
    for (const s of segments) {
      ctx.globalAlpha = s.o;
      ctx.lineWidth = s.w;
      ctx.beginPath();
      ctx.moveTo(s.x1, s.y1);
      ctx.lineTo(s.x2, s.y2);
      ctx.stroke();
    }
  }

  ctx.fillStyle = ink;
  for (const d of dots) {
    ctx.globalAlpha = d.o;
    ctx.beginPath();
    ctx.arc(d.x, d.y, d.r, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.globalAlpha = 1;
}

export type OrbProps = {
  /** Which of the app's nine states to draw. */
  state?: OrbState;
  size: number;
  className?: string;
  /** Announced to screen readers; omit for the decorative background orbs. */
  label?: string;
};

export default function Orb({ state = "listening", size, className, label }: OrbProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = size * dpr;
    canvas.height = size * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    let frame = 0;
    let ink = resolveInk();

    const run = () => {
      cancelAnimationFrame(frame);
      if (query.matches) {
        paint(ctx, size, state, STILL_TIME, ink);
        return;
      }
      const start = performance.now();
      const loop = (now: number) => {
        paint(ctx, size, state, (now - start) / 1000, ink);
        frame = requestAnimationFrame(loop);
      };
      frame = requestAnimationFrame(loop);
    };

    run();
    query.addEventListener("change", run);

    // A theme flip re-inks the orb: the animated loop picks the new colour up on its
    // next frame, the frozen still needs one explicit repaint.
    const unsubscribeTheme = subscribeTheme(() => {
      ink = resolveInk();
      if (query.matches) paint(ctx, size, state, STILL_TIME, ink);
    });

    return () => {
      cancelAnimationFrame(frame);
      query.removeEventListener("change", run);
      unsubscribeTheme();
    };
  }, [size, state]);

  return (
    <canvas
      ref={canvasRef}
      className={`orb-canvas ${className ?? ""}`}
      data-orb-state={state}
      role={label ? "img" : "presentation"}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      style={{ "--orb-size": `${size}px` } as CSSProperties}
    />
  );
}
