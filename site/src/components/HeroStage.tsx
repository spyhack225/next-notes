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
 * LAYOUT CONTRACT. Nothing here is hand-tuned to a viewport. The hero reserves a centre
 * column of `--hero-col` (index.css) for the type, and the decoration lives in lanes that
 * are defined as what is left over:
 *
 *   • the two side cards sit in `calc((100% - var(--hero-col)) / 2)` gutters, so they
 *     cannot reach the column no matter how wide the window is;
 *   • the island and the chips sit in the outer rows of the hero's
 *     `grid-rows-[minmax(0,1fr)_auto_minmax(0,1fr)]`, above and below the type rather
 *     than behind it, so they cannot reach it no matter how tall the window is.
 *
 * Everything is `aria-hidden`: every claim here is made in words elsewhere on the page, so
 * a screen reader loses nothing by skipping the decoration.
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

/**
 * With Reduce Motion on, everything is simply present. The information is the point; the
 * choreography is not, and a looping fade is exactly what that setting is asking us to stop.
 */
function useAnim() {
  const reduced = useReducedMotion();
  return (delay: number) =>
    reduced ? { initial: false, animate: { opacity: 1, y: 0, scale: 1 } } : floatIn(delay);
}

/**
 * The gutters either side of the reserved column. 1440px and up only. The lane is
 * `(viewport - 56rem) / 2` minus its own padding, which is 240px at 1440 and 160px at
 * 1280 — and a 160px card cannot hold the sentence it exists to show, so below 1440 the
 * stage is the island and the destinations alone rather than a sliver of glass.
 */
export default function HeroStage() {
  const anim = useAnim();
  const lane = { width: "calc((100% - var(--hero-col)) / 2)" };

  return (
    <div
      className="absolute inset-0 z-0 hidden min-[1440px]:block pointer-events-none select-none"
      aria-hidden="true"
    >
      {/* 1 — Dictation. The line the app is best at: what you said, and what it wrote. */}
      <div
        className="absolute inset-y-0 left-0 flex items-center justify-center px-4 2xl:px-8"
        style={lane}
      >
        <motion.div
          {...anim(0)}
          data-hero-card="dictation"
          className="w-full max-w-[300px] liquid-glass rounded-2xl p-4"
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
      </div>

      {/* 3 — The approval. The whole safety story in one card: it asks, you press. */}
      <div
        className="absolute inset-y-0 right-0 flex items-center justify-center px-4 2xl:px-8"
        style={lane}
      >
        <motion.div
          {...anim(CYCLE * 0.42)}
          data-hero-card="proposal"
          className="w-full max-w-[300px] liquid-glass rounded-2xl p-4"
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
      </div>
    </div>
  );
}

/**
 * 2 — The island, as it actually looks at the notch: two tracks, not one mix.
 *
 * Small enough to be honest at 375px, so it is the one piece of the stage that survives all
 * the way down. Lives in the hero grid's top row; `overflow-hidden` on the row means a very
 * short window drops it rather than pushing it into the headline.
 */
export function HeroStageIsland() {
  const anim = useAnim();

  return (
    <div
      className="row-start-1 self-end flex items-end justify-center w-full max-w-full overflow-hidden pb-6 md:pb-10"
      aria-hidden="true"
    >
      <motion.div
        {...anim(CYCLE * 0.22)}
        data-hero-card="island"
        className="liquid-glass rounded-full pl-3 pr-4 sm:pr-5 py-2 inline-flex items-center gap-2 sm:gap-3 max-w-full"
      >
        <span className="w-2 h-2 rounded-full bg-[#e0483c] shrink-0" />
        <span className="text-sm tabular-nums text-foreground/90">04:12</span>
        <span className="flex flex-col gap-1 w-12 sm:w-16 shrink-0">
          <span className="h-[3px] rounded-full bg-foreground/70" style={{ width: "72%" }} />
          <span className="h-[3px] rounded-full bg-foreground/40" style={{ width: "45%" }} />
        </span>
        <span className="text-[11px] text-muted-foreground whitespace-nowrap">You · Others</span>
      </motion.div>
    </div>
  );
}

/**
 * 4 — Where the approved thing lands. Below the type, because this is the consequence
 * rather than the act.
 *
 * `md` and up: the three strings are ~460px of unbreakable text, and the only way to show
 * them at 375 is to stack them into a three-line block that argues with the call to action.
 */
export function HeroStageDestinations() {
  const anim = useAnim();

  return (
    <div
      className="row-start-3 self-start hidden md:flex items-start justify-center w-full max-w-full overflow-hidden pt-8 lg:pt-12"
      aria-hidden="true"
    >
      <motion.div
        {...anim(CYCLE * 0.62)}
        data-hero-card="destinations"
        className="flex flex-wrap items-center justify-center gap-2 max-w-full"
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
