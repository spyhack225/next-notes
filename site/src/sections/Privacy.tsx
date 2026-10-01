import { motion } from "framer-motion";
import Orb from "../components/Orb";
import { fadeUp } from "../lib/motion";

export default function Privacy() {
  return (
    <section id="privacy" className="relative overflow-hidden px-6 sm:px-8 md:px-16 lg:px-28 py-28 md:py-40 border-t border-border/40 scroll-mt-16">
      <div className="max-w-7xl mx-auto grid xl:grid-cols-2 gap-12 xl:gap-24 items-center">
        <motion.div {...fadeUp(0)} className="relative flex justify-center items-center min-h-80" aria-hidden="true">
          <Orb state="breathing" size={310} />
        </motion.div>
        <div>
          <motion.p {...fadeUp(0)} className="text-xs uppercase tracking-eyebrow text-muted-foreground">Help you can see and trust</motion.p>
          <motion.h2 {...fadeUp(0.1)} className="text-4xl sm:text-5xl lg:text-6xl tracking-section leading-section mt-6">
            Your life is personal. <span className="font-serif italic">The help should be, too.</span>
          </motion.h2>
          <motion.p {...fadeUp(0.18)} className="text-lg leading-relaxed text-muted-foreground mt-7">
            Next Notes can learn the names you use and help with the plans on your calendar. Your speech and meeting notes are handled on your Mac by default, with no account to create and no extra guest joining your calls.
          </motion.p>
          <motion.p {...fadeUp(0.26)} className="text-base leading-relaxed text-muted-foreground mt-5">
            See what it worked on in Activity. When it proposes a message or a calendar change, you can review the exact action before it happens.
          </motion.p>
          <motion.div {...fadeUp(0.34)} className="mt-9 pt-6 border-t border-border/60 grid sm:grid-cols-2 gap-6 text-sm">
            <p><span className="block text-foreground font-medium mb-2">Look back at the work.</span><span className="text-muted-foreground">Activity shows what Next Notes has been doing for you.</span></p>
            <p><span className="block text-foreground font-medium mb-2">Have the last word.</span><span className="text-muted-foreground">A proposed message or change waits for your approval.</span></p>
          </motion.div>
        </div>
      </div>
    </section>
  );
}
