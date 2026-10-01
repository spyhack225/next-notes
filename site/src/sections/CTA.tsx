import { motion } from "framer-motion";
import { ArrowUpRight } from "lucide-react";
import Orb from "../components/Orb";
import { fadeUp, DOWNLOAD_URL, REPO_URL } from "../lib/motion";

export default function CTA() {
  return (
    <section className="relative overflow-hidden border-t border-border/40 px-6 sm:px-8 md:px-16 lg:px-28 py-32 md:py-44 text-center">
      <div className="absolute inset-0 flex items-center justify-center opacity-20 pointer-events-none" aria-hidden="true">
        <div className="scale-cta-backdrop sm:scale-cta-backdrop-lg md:scale-100"><Orb state="connecting" size={560} /></div>
      </div>
      <div className="relative z-10 max-w-3xl mx-auto">
        <motion.p {...fadeUp(0)} className="text-xs uppercase tracking-eyebrow text-muted-foreground">One companion. Start on your Mac.</motion.p>
        <motion.h2 {...fadeUp(0.1)} className="text-5xl sm:text-6xl lg:text-7xl tracking-display leading-display mt-7">
          Give your attention to <span className="font-serif italic">what matters.</span>
        </motion.h2>
        <motion.p {...fadeUp(0.2)} className="text-lg text-muted-foreground leading-relaxed mt-7 max-w-xl mx-auto">
          Ask about tomorrow&apos;s plan. Speak the reply you&apos;ve been putting off. Let your next meeting end with notes you can actually use. Come back to the same Next Notes for what comes next.
        </motion.p>
        <motion.div {...fadeUp(0.3)} className="flex flex-wrap justify-center items-center gap-6 mt-10">
          <motion.a href={DOWNLOAD_URL} whileHover={{ y: -3 }} whileTap={{ scale: 0.98 }} className="inline-flex items-center gap-3 bg-foreground text-background rounded-full px-8 py-4 text-sm font-medium">
            Download for Mac <ArrowUpRight size={17} aria-hidden="true" />
          </motion.a>
          <a href={REPO_URL} target="_blank" rel="noreferrer" className="text-sm text-muted-foreground hover:text-foreground transition-colors">View source</a>
        </motion.div>
        <motion.p {...fadeUp(0.4)} className="text-xs text-muted-foreground mt-7">Free and open source · macOS 26 on Apple silicon</motion.p>
      </div>
    </section>
  );
}
