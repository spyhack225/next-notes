import { motion } from "framer-motion";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp } from "../lib/motion";

/**
 * The sequence, told as what the user stops having to do.
 *
 * Deliberately not a feature list — that is the grid further down. Each step here is named
 * for the chore it removes, because nobody wants two-track audio capture; they want to stop
 * writing up meetings. The mechanism is the small print underneath.
 */
const STEPS: {
  n: string;
  orb: OrbState;
  value: string;
  body: string;
  detail: string;
}[] = [
  {
    n: "01",
    orb: "listening",
    value: "You stop typing",
    body: "Most of what you write in a day is short and forgettable — a reply, a commit message, a note to yourself. Say it instead and carry on.",
    detail: "Hold a key anywhere. The cleaned-up sentence appears at the cursor.",
  },
  {
    n: "02",
    orb: "weaving",
    value: "You stop taking notes",
    body: "Give the meeting your attention instead of your typing hand. Nothing joins the call, so nobody has to agree to a stranger in the room.",
    detail: "Your calendar starts it. Your mic and the room are kept as separate tracks.",
  },
  {
    n: "03",
    orb: "searching",
    value: "You stop chasing the admin",
    body: "The half hour after a meeting is where the work actually leaks away. The follow-ups are drafted before you have left the call.",
    detail: "It offers; you approve. Nothing is created or sent on its own.",
  },
  {
    n: "04",
    orb: "connecting",
    value: "You stop switching tools",
    body: "It lands where the work already lives, so there is no second inbox to check and nothing to copy across in the morning.",
    detail: "Calendar, Gmail, Drive and Docs — in your own account, as you.",
  },
];

export default function HowItWorks() {
  return (
    <section
      id="how-it-works"
      className="py-32 md:py-44 px-8 md:px-28 border-t border-border/30 scroll-mt-28"
    >
      <div className="max-w-6xl mx-auto">
        <motion.p
          {...fadeUp(0)}
          className="text-xs tracking-[3px] uppercase text-muted-foreground text-center"
        >
          How it works
        </motion.p>

        <motion.h2
          {...fadeUp(0.1)}
          className="text-4xl md:text-6xl font-medium tracking-[-1.5px] text-center mt-6 leading-[1.05]"
        >
          Four things you no longer{" "}
          <span className="font-serif italic font-normal">have to do.</span>
        </motion.h2>

        <div className="mt-20 grid gap-12 md:gap-8 md:grid-cols-2 lg:grid-cols-4">
          {STEPS.map((s, i) => (
            <motion.div key={s.n} {...fadeUp(0.15 + i * 0.08)} className="flex flex-col">
              <div className="flex items-center gap-3 mb-6">
                <Orb state={s.orb} size={64} />
                <span className="text-xs tabular-nums tracking-[0.2em] text-muted-foreground">
                  {s.n}
                </span>
              </div>

              <h3 className="font-semibold text-lg tracking-[-0.01em]">{s.value}</h3>
              <p className="text-muted-foreground text-sm leading-relaxed mt-3">{s.body}</p>

              <p className="text-muted-foreground/60 text-xs leading-relaxed mt-4 pt-4 border-t border-border/40">
                {s.detail}
              </p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
