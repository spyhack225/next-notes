import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { ArrowUpRight, Check, Mic2 } from "lucide-react";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp } from "../lib/motion";

const scenes: {
  label: string;
  role: string;
  context: string;
  title: string;
  story: string;
  ask: string;
  answer: string;
  result: string;
  orb: OrbState;
}[] = [
  {
    label: "For home",
    role: "Home helper",
    context: "The family plan",
    title: "Be the one who shows up.",
    story: "Pickup is on your mind while the workday is still going. Ask how your calendar looks, make the plan, and get back to the people who need you.",
    ask: "Do I have time to pick up the kids after work?",
    answer: "Your last meeting ends at 3:30. The rest of the afternoon is clear.",
    result: "A plan made. One less thing to hold in your head.",
    orb: "searching",
  },
  {
    label: "For work",
    role: "Office associate",
    context: "The reply that can't wait",
    title: "Make progress on work that matters.",
    story: "You know what to say, but typing it would pull you away. Hold a key, speak naturally, and your words appear where your cursor was.",
    ask: "Thursday works for me. Could you send over the agenda beforehand?",
    answer: "Thursday works for me. Could you send over the agenda beforehand?",
    result: "The reply is done. Your attention stays on the work.",
    orb: "listening",
  },
  {
    label: "Across your Mac",
    role: "Office associate",
    context: "The apps you already use",
    title: "Keep work moving between apps.",
    story: "A decision belongs in Notes, and the details are in your meeting. Ask Next Notes to prepare the change in the app you use, then approve it before it types.",
    ask: "Put the decisions from that meeting in Notes for me.",
    answer: "I found the decisions and can add them to Notes. Here's what I'd write for your review.",
    result: "A hand across your Mac, with you in charge.",
    orb: "working",
  },
  {
    label: "For your promises",
    role: "Meeting partner",
    context: "The promise you made",
    title: "Be someone who follows through.",
    story: "With calendar meeting recording on, Next Notes gets ready before the call. Afterward, it writes down what was decided and can prepare a follow-up for your review.",
    ask: "I’ll send Maya the deck after this.",
    answer: "Maya needs the deck. I’ve drafted a follow-up for you to review.",
    result: "The next step is ready before it slips away.",
    orb: "composing",
  },
];

export default function WhatItDoes() {
  const [active, setActive] = useState(0);
  const scene = scenes[active];

  return (
    <section id="impact" className="px-6 sm:px-8 md:px-16 lg:px-28 py-28 md:py-40 border-t border-border/40 scroll-mt-16">
      <div className="max-w-7xl mx-auto">
        <motion.div {...fadeUp(0)} className="max-w-3xl">
          <p className="text-xs uppercase tracking-eyebrow text-muted-foreground">One companion, different moments</p>
          <h2 className="text-4xl sm:text-5xl lg:text-7xl tracking-section leading-section mt-5">
            One companion for <span className="font-serif italic">the day you have.</span>
          </h2>
          <p className="text-lg text-muted-foreground leading-relaxed mt-6 max-w-2xl">
            Next Notes starts on your Mac. It can be your home helper for the family plan, your office associate while work moves between apps, and your meeting partner when a promise needs remembering. The role changes with the moment. The companion stays the same.
          </p>
        </motion.div>

        <div className="grid xl:grid-cols-12 gap-8 xl:gap-16 mt-14 md:mt-20 items-start">
          <div className="xl:col-span-4 flex flex-col gap-3" role="group" aria-label="Choose a moment">
            {scenes.map((item, index) => (
              <button
                type="button"
                aria-pressed={active === index}
                key={item.label}
                onClick={() => setActive(index)}
                className={`text-left rounded-2xl px-5 py-5 sm:px-6 border transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground ${active === index ? "border-foreground/40 bg-card" : "border-border/50 hover:border-foreground/30"}`}
              >
                <span className="text-xs text-muted-foreground uppercase tracking-caption">0{index + 1} / {item.label}</span>
                <span className="block text-lg sm:text-xl mt-2 font-medium">{item.role}</span>
                <span className="block text-sm text-muted-foreground mt-2">{item.result}</span>
              </button>
            ))}
          </div>

          <div id="day-scene" role="region" aria-label={`${scene.label} example`} className="xl:col-span-8 min-h-128">
            <div className="flex items-start gap-3 pb-5 px-1">
              <Orb state="breathing" size={31} className="shrink-0" />
              <div className="min-w-0 flex-1 sm:flex sm:items-center sm:justify-between sm:gap-4">
                <div className="min-w-0">
                  <p className="text-sm font-medium">Next Notes</p>
                  <p className="text-xs text-muted-foreground">The same companion, here as your {scene.role.toLowerCase()}</p>
                </div>
                <span className="block mt-1 text-xs text-muted-foreground sm:mt-0 sm:text-right">Your conversation continues on your Mac</span>
              </div>
            </div>
            <AnimatePresence mode="wait">
              <motion.div
                key={scene.label}
                initial={{ opacity: 0, y: 18 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -12 }}
                transition={{ duration: 0.4, ease: "easeOut" }}
                className="liquid-glass rounded-3xl border border-border/40 overflow-hidden"
              >
                <div className="grid md:grid-cols-2">
                  <div className="p-7 sm:p-10 md:p-12 flex flex-col justify-between min-h-80">
                    <div>
                      <p className="text-xs text-muted-foreground uppercase tracking-caption">{scene.context}</p>
                      <h3 className="text-3xl sm:text-4xl tracking-section leading-section mt-8">{scene.title}</h3>
                      <p className="text-muted-foreground leading-relaxed mt-6">{scene.story}</p>
                    </div>
                    <div className="mt-10 flex items-center gap-2 text-sm">
                      <Check size={18} aria-hidden="true" />
                      <span>{scene.result}</span>
                    </div>
                  </div>
                  <div className="bg-card/70 border-t md:border-t-0 md:border-l border-border/40 p-6 sm:p-8 md:p-10 flex flex-col justify-center min-h-96">
                    <div className="flex items-center gap-2 mb-7">
                      <Orb state={scene.orb} size={36} />
                      <span className="text-xs text-muted-foreground uppercase tracking-caption">One moment from the same day</span>
                    </div>
                    <motion.div initial={{ opacity: 0, x: 12 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: 0.22 }} className="self-end max-w-xs bg-secondary rounded-2xl rounded-br-sm p-4 text-sm leading-relaxed">
                      <div className="flex items-center gap-2 text-xs text-muted-foreground mb-2"><Mic2 size={13} aria-hidden="true" /> You said</div>
                      “{scene.ask}”
                    </motion.div>
                    <motion.div initial={{ opacity: 0, x: -12 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: 0.48 }} className="self-start max-w-sm bg-background border border-border/50 rounded-2xl rounded-tl-sm p-4 text-sm leading-relaxed mt-5">
                      <div className="text-xs text-muted-foreground mb-2">{scene.label === "For work" ? "Typed where you were writing" : "Next Notes"}</div>
                      {scene.answer}
                    </motion.div>
                    <div className="mt-8 pt-5 border-t border-border/50 text-xs text-muted-foreground flex items-center gap-2">
                      <ArrowUpRight size={15} aria-hidden="true" />
                      An example of help from the same Next Notes.
                    </div>
                  </div>
                </div>
              </motion.div>
            </AnimatePresence>
          </div>
        </div>
      </div>
    </section>
  );
}
