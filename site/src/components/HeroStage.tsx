import { motion, useReducedMotion } from "framer-motion";
import Orb from "./Orb";

/**
 * The app happening, around the headline.
 *
 * Not a screenshot and not a mockup of one. These are the four moments the app is actually
 * for — a sentence being cleaned up, a meeting being recorded, a follow-up being offered,
 * and the approved thing landing in Google — drawn in the page's own vocabulary and
 * surfacing on a slow loop so the hero is never still.
 *
 * They sit behind the type (`z-0`, headline is `z-10`) and are hidden below `lg`, where
 * there is no room beside a 96px headline for anything to float without colliding with it.
 * `aria-hidden` throughout: every claim here is made in words elsewhere on the page, so a
 * screen reader loses nothing by skipping the decoration.
 */

/** One appear → hold → leave cycle, shared by every card so the rhythm reads as one thing. */
const CYCLE = 16;

function floatIn(delay: number) {
  return {
    initial: { opacity: 0, y: 14, scale: 0.97 },
    animate: {
      opacity: [0, 1, 1, 0],
      y: [14, 0, 0, -10],
      scale: [0.97, 1, 1, 0.99],
    },
    transition: {
      duration: CYCLE,
      times: [0, 0.06, 0.28, 0.36],
      repeat: Infinity,
      delay,
      ease: "easeOut" as const,
    },
  };
}

export default function HeroStage() {
  const reduced = useReducedMotion();

  // With Reduce Motion on, everything is simply present. The information is the point; the
  // choreography is not, and a looping fade is exactly what that setting is asking us to stop.
  const anim = (delay: number) =>
    reduced ? { initial: false, animate: { opacity: 1, y: 0, scale: 1 } } : floatIn(delay);

  return (
    <div
      className="absolute inset-0 z-0 hidden lg:block pointer-events-none select-none"
      aria-hidden="true"
    >
      {/* 1 — Dictation. The line the app is best at: what you said, and what it wrote. */}
      <motion.div
        {...anim(0)}
        className="absolute left-[4%] xl:left-[7%] top-[26%] w-[280px] liquid-glass rounded-2xl p-4"
      >
        <div className="flex items-center gap-2 mb-3">
          <Orb state="listening" size={28} />
          <span className="text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
            Dictating
          </span>
        </div>
        <p className="text-xs text-muted-foreground/70 leading-relaxed line-through decoration-muted-foreground/40">
          um so i need to send the report by friday no wait make that thursday
        </p>
        <p className="text-sm text-foreground/90 leading-relaxed mt-2">
          So I need to send the report by Thursday.
        </p>
      </motion.div>

      {/* 2 — The island, as it actually looks at the notch: two tracks, not one mix. */}
      <motion.div
        {...anim(CYCLE * 0.22)}
        className="absolute left-1/2 -translate-x-1/2 top-[13%] liquid-glass rounded-full pl-3 pr-5 py-2 flex items-center gap-3"
      >
        <span className="w-2 h-2 rounded-full bg-[#e0483c] shrink-0" />
        <span className="text-sm tabular-nums text-foreground/90">04:12</span>
        <span className="flex flex-col gap-1 w-16">
          <span className="h-[3px] rounded-full bg-foreground/70" style={{ width: "72%" }} />
          <span className="h-[3px] rounded-full bg-foreground/40" style={{ width: "45%" }} />
        </span>
        <span className="text-[11px] text-muted-foreground">You · Others</span>
      </motion.div>

      {/* 3 — The approval. The whole safety story in one card: it asks, you press. */}
      <motion.div
        {...anim(CYCLE * 0.42)}
        className="absolute right-[4%] xl:right-[7%] top-[40%] w-[290px] liquid-glass rounded-2xl p-4"
      >
        <div className="flex items-center gap-2 mb-3">
          <Orb state="searching" size={28} />
          <span className="text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
            Proposed
          </span>
        </div>
        <p className="text-sm text-foreground/90 leading-relaxed">
          Schedule &ldquo;Cutover&rdquo; — Wednesday the 22nd, 10:00
        </p>
        <div className="flex items-center gap-2 mt-3">
          <span className="text-[11px] rounded-full bg-foreground text-background px-3 py-1">
            Approve
          </span>
          <span className="text-[11px] rounded-full px-3 py-1 text-muted-foreground border border-border">
            Dismiss
          </span>
        </div>
      </motion.div>

      {/* 4 — Where the approved thing lands. Behind the type, low and wide, because this is
             the consequence rather than the act. */}
      <motion.div
        {...anim(CYCLE * 0.62)}
        className="absolute left-1/2 -translate-x-1/2 bottom-[16%] flex items-center gap-2"
      >
        <Orb state="connecting" size={28} />
        {["Calendar — invite sent", "Gmail — draft ready", "Drive — notes saved"].map((t) => (
          <span
            key={t}
            className="liquid-glass rounded-full px-4 py-2 text-[11px] text-muted-foreground whitespace-nowrap"
          >
            {t}
          </span>
        ))}
      </motion.div>
    </div>
  );
}
