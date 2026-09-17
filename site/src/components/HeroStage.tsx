import { motion, useReducedMotion } from "framer-motion";
import Orb from "./Orb";

/**
 * The app happening, around the headline.
 *
 * Not a screenshot and not a mockup of one. These are the moments the app is actually
 * for — a voice ask, an approval, context on the machine, a follow-up landing where the
 * work already lives — drawn in the page's own vocabulary and surfacing on a slow loop so
 * the hero is never still.
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
      {/* 1 — A voice ask. The Mac already has the context; the agent answers from it. */}
      <div
        className="absolute inset-y-0 left-0 flex items-center justify-center px-4 2xl:px-8"
        style={lane}
      >
        <motion.div
          {...anim(0)}
          data-hero-card="ask"
          className="w-full max-w-[300px] liquid-glass rounded-2xl p-4"
        >
          <div className="flex items-center gap-2 mb-3">
            <Orb state="listening" size={28} />
            <span className="text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
              Asking
            </span>
          </div>
          <p className="text-xs text-muted-foreground/70 leading-relaxed">
            What&apos;s on tomorrow after three?
          </p>
          <p className="text-sm text-foreground/90 leading-relaxed mt-2">
            You&apos;re clear after three. Want me to draft a reply?
          </p>
        </motion.div>
      </div>

      {/* 5 — Acting on the Mac. Same gutter; it arrives after that card leaves. */}
      <div
        className="absolute inset-y-0 left-0 flex items-center justify-center px-4 2xl:px-8"
        style={lane}
      >
        <motion.div
          {...anim(CYCLE * 0.48)}
          data-hero-card="agent"
          className="w-full max-w-[300px] liquid-glass rounded-2xl p-4"
        >
          <div className="flex items-center gap-2 mb-3">
            <Orb state="searching" size={28} />
            <span className="text-[11px] uppercase tracking-[0.14em] text-muted-foreground">
              Acting
            </span>
          </div>
          <p className="text-xs text-muted-foreground/70 leading-relaxed">
            Click Run in the front window.
          </p>
          <p className="text-sm text-foreground/90 leading-relaxed mt-2">
            Clicked. Done.
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
 * 2 — The island, as it actually looks at the notch: the agent present while you work.
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
        <Orb state="listening" size={22} />
        <span className="text-sm text-foreground/90 whitespace-nowrap">Listening</span>
        <span className="text-[11px] text-muted-foreground whitespace-nowrap">
          just you · on this Mac
        </span>
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
        {["It remembers you", "It stays local", "It waits on you"].map((t) => (
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
