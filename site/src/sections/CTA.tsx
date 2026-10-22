import { motion } from "framer-motion";
import Orb from "../components/Orb";
import GetItOnMac from "../components/GetItOnMac";
import { fadeUp, REPO_URL } from "../lib/motion";

export default function CTA() {
  return (
    <section className="relative overflow-hidden border-t border-border/40 px-6 sm:px-8 md:px-16 lg:px-28 py-16 md:py-20 text-center">
      <div className="absolute inset-0 flex items-center justify-center opacity-20 pointer-events-none" aria-hidden="true">
        <div className="scale-cta-backdrop sm:scale-cta-backdrop-lg md:scale-100"><Orb state="connecting" size={560} /></div>
      </div>
      <div className="relative z-10 max-w-3xl mx-auto">
        <motion.p {...fadeUp(0)} className="text-xs uppercase tracking-eyebrow text-muted-foreground">Still in development</motion.p>
        <motion.h2 {...fadeUp(0.1)} className="text-5xl sm:text-6xl lg:text-7xl tracking-display leading-display mt-7">
          Someone in your corner, <span className="font-serif italic">starting today.</span>
        </motion.h2>
        <motion.p {...fadeUp(0.2)} className="text-lg text-muted-foreground leading-relaxed mt-7 max-w-xl mx-auto">
          Dictation, meeting notes and answers about your week and your inbox work today. Your catch-up and the rest are on their way. It&apos;s early, so expect a few rough edges.
        </motion.p>
        <motion.div {...fadeUp(0.3)} className="flex flex-wrap justify-center items-start gap-x-8 gap-y-5 mt-10">
          <GetItOnMac align="center" />
          <a href={REPO_URL} target="_blank" rel="noreferrer" className="text-sm text-muted-foreground hover:text-foreground transition-colors">Check how it&apos;s built</a>
        </motion.div>
        <motion.p {...fadeUp(0.4)} className="text-xs text-muted-foreground mt-7">Built to stay on your Mac · Any Apple-silicon Mac · Needs macOS 26</motion.p>
      </div>
    </section>
  );
}
