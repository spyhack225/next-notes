import { motion } from "framer-motion";
import Orb from "../components/Orb";
import StatusPill from "../components/StatusPill";
import { fadeUp } from "../lib/motion";

export default function Privacy() {
  return (
    <section id="privacy" className="relative overflow-hidden px-6 sm:px-8 md:px-16 lg:px-28 py-16 md:py-24 border-t border-border/40 scroll-mt-16">
      <div className="max-w-7xl mx-auto grid xl:grid-cols-2 gap-12 xl:gap-24 items-center">
        <motion.div {...fadeUp(0)} className="relative hidden xl:flex justify-center items-center min-h-80" aria-hidden="true">
          <Orb state="breathing" size={310} />
        </motion.div>
        <div>
          <motion.p {...fadeUp(0)} className="text-xs uppercase tracking-eyebrow text-muted-foreground">Your things stay yours</motion.p>
          <motion.h2 {...fadeUp(0.1)} className="text-4xl sm:text-5xl tracking-section leading-section mt-5">
            What&apos;s yours <span className="font-serif italic">stays yours.</span>
          </motion.h2>
          <motion.p {...fadeUp(0.18)} className="text-lg leading-relaxed text-muted-foreground mt-6">
            Your kids&apos; schedule, your clients&apos; cases, your team&apos;s inbox, your unreleased footage. It&apos;s built to do its work on the Mac in front of you, so all of it stays there. When something has to go further, like your Google calendar, it tells you first.
          </motion.p>
          <motion.p {...fadeUp(0.26)} className="text-base leading-relaxed text-muted-foreground mt-5">
            Anyone can check how it&apos;s built, so you never have to take our word for it. Nothing leaves unless you say so.
          </motion.p>
          <motion.div {...fadeUp(0.34)} className="mt-7 pt-6 border-t border-border/60 grid sm:grid-cols-2 gap-6 text-sm">
            <p><span className="block mb-3"><StatusPill status="soon" /></span><span className="block text-foreground font-medium mb-2">Helping the moment you open it.</span><span className="text-muted-foreground">No account, no settings, nothing to pick or download, and your Google mail and calendar connected without the setup steps. You just start talking.</span></p>
            <p><span className="block mb-3"><StatusPill status="progress" /></span><span className="block text-foreground font-medium mb-2">Quick on the Mac you already have.</span><span className="text-muted-foreground">Built to keep up with you on the Mac you already have, even a 16 GB MacBook Air, so there&apos;s nothing new to buy.</span></p>
          </motion.div>
        </div>
      </div>
    </section>
  );
}
