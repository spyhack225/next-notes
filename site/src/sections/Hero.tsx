import { motion } from "framer-motion";
import HeroStage, { HeroStageIsland, HeroStageDestinations } from "../components/HeroStage";
import Orb from "../components/Orb";
import { fadeUp, DOWNLOAD_URL, REPO_URL } from "../lib/motion";

/**
 * Three rows, not a stack.
 *
 * The hero has to hold the type and four pieces of decoration without the two ever
 * touching, at every width from a phone to a 5K display. Percentage offsets cannot promise
 * that — they only happen to work at the width they were tuned at — so the promise is
 * structural instead:
 *
 *   • the type owns the middle row and is capped at `--hero-col`;
 *   • the island and the destinations own the outer rows, above and below it;
 *   • the two side cards are absolutely positioned into the gutters that `--hero-col`
 *     leaves over, so they cannot reach the column however wide the window gets.
 *
 * The outer rows are `minmax(0, 1fr)`, so on a short window they give up their height to
 * the type rather than pushing decoration into it.
 */
export default function Hero() {
  return (
    <section
      id="top"
      className="relative min-h-screen grid grid-rows-[minmax(0,1fr)_auto_minmax(0,1fr)] justify-items-center px-6 sm:px-8 md:px-28 overflow-hidden"
    >
      {/* No stock video here, or anywhere. The mark itself is the backdrop — the slow
          face-on ring, so it sits behind the headline rather than competing with it.
          Absolute, so it takes no row of its own. */}
      <div
        className="absolute inset-0 flex items-center justify-center pointer-events-none"
        aria-hidden="true"
      >
        {/* 520px of canvas is wider than a phone. Scale rather than crop: the ring is
            the mark, and a cropped ring reads as a mistake. */}
        <div className="opacity-50 scale-[0.62] sm:scale-[0.85] md:scale-100">
          <Orb state="breathing" size={520} />
        </div>
      </div>
      <HeroStage />
      <div className="absolute bottom-0 left-0 right-0 h-64 bg-gradient-to-t from-background to-transparent pointer-events-none z-[1]" />

      <HeroStageIsland />

      <div
        className="row-start-2 relative z-10 flex flex-col items-center text-center w-full"
        style={{ maxWidth: "var(--hero-col)" }}
      >
        <motion.h1
          {...fadeUp(0)}
          className="text-4xl sm:text-5xl md:text-7xl lg:text-8xl font-medium tracking-[-1px] sm:tracking-[-2px] leading-[1.02]"
        >
          Stop <span className="font-serif italic font-normal">typing</span>.
          <br />
          Stop taking <span className="font-serif italic font-normal">notes</span>.
        </motion.h1>

        <motion.p
          {...fadeUp(0.15)}
          className="mt-6 sm:mt-7 text-base sm:text-lg max-w-xl leading-relaxed"
          style={{ color: "hsl(var(--hero-subtitle))" }}
        >
          Speak into any app and the words appear. Sit in any meeting and the notes write
          themselves. All of it happens on your Mac.
        </motion.p>

        <motion.div
          {...fadeUp(0.3)}
          className="mt-8 sm:mt-10 liquid-glass rounded-full p-2 flex items-center gap-1 max-w-full"
        >
          <motion.a
            href={DOWNLOAD_URL}
            whileHover={{ scale: 1.03 }}
            whileTap={{ scale: 0.98 }}
            className="bg-foreground text-background rounded-full px-6 sm:px-8 py-3 text-sm font-medium inline-block whitespace-nowrap"
          >
            Download for Mac
          </motion.a>
          <a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="rounded-full px-5 sm:px-6 py-3 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors whitespace-nowrap"
          >
            View source
          </a>
        </motion.div>

        <motion.p {...fadeUp(0.45)} className="mt-6 text-muted-foreground text-sm">
          macOS 26 &middot; Apple silicon &middot; free and open source
        </motion.p>
      </div>

      <HeroStageDestinations />
    </section>
  );
}
