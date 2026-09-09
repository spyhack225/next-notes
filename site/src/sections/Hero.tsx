import { motion } from "framer-motion";
import Orb from "../components/Orb";
import { fadeUp, REPO_URL } from "../lib/motion";

export default function Hero() {
  return (
    <section
      id="top"
      className="relative min-h-screen flex flex-col items-center justify-center px-8 md:px-28 overflow-hidden"
    >
      {/* No stock video here, or anywhere. The mark itself is the backdrop. */}
      <div
        className="absolute inset-0 flex items-center justify-center pointer-events-none"
        aria-hidden="true"
      >
        <div className="opacity-50">
          <Orb size={520} />
        </div>
      </div>
      <div className="absolute bottom-0 left-0 right-0 h-64 bg-gradient-to-t from-background to-transparent pointer-events-none" />

      <div className="relative z-10 flex flex-col items-center text-center max-w-4xl">
        <motion.h1
          {...fadeUp(0)}
          className="text-5xl md:text-7xl lg:text-8xl font-medium tracking-[-2px] leading-[1.02]"
        >
          Stop <span className="font-serif italic font-normal">typing</span>.
          <br />
          Stop taking <span className="font-serif italic font-normal">notes</span>.
        </motion.h1>

        <motion.p
          {...fadeUp(0.15)}
          className="mt-7 text-lg max-w-xl leading-relaxed"
          style={{ color: "hsl(var(--hero-subtitle))" }}
        >
          Speak into any app and the words appear. Sit in any meeting and the notes write
          themselves. All of it happens on your Mac.
        </motion.p>

        <motion.div
          {...fadeUp(0.3)}
          className="mt-10 liquid-glass rounded-full p-2 flex items-center gap-1"
        >
          <motion.a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            whileHover={{ scale: 1.03 }}
            whileTap={{ scale: 0.98 }}
            className="bg-foreground text-background rounded-full px-8 py-3 text-sm font-medium inline-block"
          >
            Get Speechify
          </motion.a>
          <a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="rounded-full px-6 py-3 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors"
          >
            View source
          </a>
        </motion.div>

        <motion.p {...fadeUp(0.45)} className="mt-6 text-muted-foreground text-sm">
          macOS 26 &middot; Apple silicon &middot; free and open source
        </motion.p>
      </div>
    </section>
  );
}
