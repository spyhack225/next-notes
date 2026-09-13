import { motion } from "framer-motion";
import Orb from "../components/Orb";
import { fadeUp, DOWNLOAD_URL, REPO_URL } from "../lib/motion";

export default function CTA() {
  return (
    <section className="py-32 md:py-44 border-t border-border/30 overflow-hidden relative px-8 md:px-28">
      <div
        className="absolute inset-0 flex items-center justify-center pointer-events-none opacity-30"
        aria-hidden="true"
      >
        <div className="scale-[0.6] sm:scale-[0.8] md:scale-100">
          <Orb state="connecting" size={560} />
        </div>
      </div>
      <div className="absolute inset-0 bg-background/45 z-[1] pointer-events-none" />

      <div className="relative z-10 flex flex-col items-center text-center">
        <motion.div {...fadeUp(0)}>
          <Orb size={40} />
        </motion.div>

        <motion.h2
          {...fadeUp(0.1)}
          className="text-4xl md:text-6xl font-medium tracking-[-1.5px] mt-8"
        >
          Start <span className="font-serif italic font-normal">talking.</span>
        </motion.h2>

        <motion.p
          {...fadeUp(0.2)}
          className="text-muted-foreground text-lg mt-6 max-w-xl leading-relaxed"
        >
          Download the app, or clone the repo and run{" "}
          <code className="text-foreground/80">make install</code>. The disk image is small;
          speech and notes models download on first use. The build is not notarized yet, so
          the first open is right-click the app and choose Open.
        </motion.p>

        <motion.div {...fadeUp(0.3)} className="flex flex-wrap gap-4 justify-center mt-10">
          <motion.a
            href={DOWNLOAD_URL}
            whileHover={{ scale: 1.03 }}
            whileTap={{ scale: 0.98 }}
            className="bg-foreground text-background rounded-lg px-8 py-3.5 text-sm font-medium inline-block"
          >
            Download for Mac
          </motion.a>
          <motion.a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            whileHover={{ scale: 1.03 }}
            whileTap={{ scale: 0.98 }}
            className="liquid-glass rounded-lg px-8 py-3.5 text-sm font-medium inline-block text-foreground"
          >
            View source
          </motion.a>
        </motion.div>
      </div>
    </section>
  );
}
