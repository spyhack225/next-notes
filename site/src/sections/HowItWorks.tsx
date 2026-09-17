import { motion } from "framer-motion";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp } from "../lib/motion";

/**
 * The sequence, told as what you stop having to do — and what “it” starts doing for you.
 *
 * Same personal register as the original page: short sentences, you / it, the chore named
 * first. The agent positioning lives underneath, not as a positioning deck.
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
    orb: "breathing",
    value: "You stop teaching a stranger",
    body: "Your Mac already has your files, your calendar, the jargon you actually use. The best agent does not need a new home — it needs to live where you already are.",
    detail: "Memory, storage and a local model — already on the machine in front of you.",
  },
  {
    n: "02",
    orb: "listening",
    value: "You stop typing everything",
    body: "Hold a key. Say the thing. Ask it the next thing. Voice is how you reach an agent that already sits at your desk — and everything you say stays here.",
    detail: "⇧⌘ Space, push-to-talk, or “Hey Next”. Silence ends a turn; Done leaves.",
  },
  {
    n: "03",
    orb: "searching",
    value: "You stop driving the Mac by hand",
    body: "Ask what’s on the calendar, what was just decided, or to click the button in front of you. It can look, then act, in more than one step. A yes can be scoped to an app, a site or a folder.",
    detail: "Inspect, click, type, open a file, run a command. Never sudo. Never a blanket yes.",
  },
  {
    n: "04",
    orb: "composing",
    value: "You stop repeating yourself",
    body: "It keeps the thread — the meeting you were in, the name it learned last week, the draft you almost sent. The next ask starts from where you left off, not from a blank chat.",
    detail: "One folder per meeting. A dictionary of your names. Proposals that wait on you.",
  },
  {
    n: "05",
    orb: "connecting",
    value: "You stop chasing the follow-up",
    body: "When you approve, it writes the doc, puts the event on Calendar and sends the mail — as you. Nothing is created or sent on its own.",
    detail: "Gmail, Calendar, Drive and Docs — your account, your say.",
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
          What you no longer{" "}
          <span className="font-serif italic font-normal">have to do.</span>
        </motion.h2>

        <div className="mt-20 grid gap-12 md:gap-8 md:grid-cols-2 lg:grid-cols-3">
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
