import { motion } from "framer-motion";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp } from "../lib/motion";

const moments: { time: string; title: string; body: string; orb: OrbState }[] = [
  {
    time: "Before the call",
    title: "The meeting is already on its radar.",
    body: "When an eligible meeting comes up on your calendar, Next Notes gets ready. You can record now or skip it.",
    orb: "searching",
  },
  {
    time: "During the call",
    title: "You can stay in the conversation.",
    body: "With recording on, you can listen, ask questions, and respond to the people in the room instead of trying to write everything down.",
    orb: "listening",
  },
  {
    time: "When it ends",
    title: "The details are there when you need them.",
    body: "When automatic notes are on, Next Notes writes what was decided and who owes what. Open the meeting later and pick up where you left off.",
    orb: "weaving",
  },
  {
    time: "Before anything goes out",
    title: "The follow-up is yours to send.",
    body: "If follow-up suggestions are on, Next Notes can prepare a message from the meeting. Read it, edit it, and approve it before anything goes out.",
    orb: "composing",
  },
];

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="px-6 sm:px-8 md:px-16 lg:px-28 py-28 md:py-40 border-t border-border/40 scroll-mt-16">
      <div className="max-w-7xl mx-auto grid xl:grid-cols-12 gap-14 xl:gap-20">
        <motion.div {...fadeUp(0)} className="xl:col-span-5 xl:sticky xl:top-36 self-start">
          <p className="text-xs uppercase tracking-eyebrow text-muted-foreground">A meeting, from start to follow-up</p>
          <h2 className="text-4xl sm:text-5xl lg:text-6xl tracking-section leading-section mt-6">
            It keeps the thread. <span className="font-serif italic">You keep your attention.</span>
          </h2>
          <p className="text-lg text-muted-foreground leading-relaxed mt-7 max-w-lg">
            Turn on calendar meeting recording, and Next Notes can get ready for an upcoming call. When it ends, the decisions are written down and a follow-up can be waiting for your review.
          </p>
          <p className="text-sm text-muted-foreground leading-relaxed mt-5 max-w-lg">
            This is the same Next Notes you ask about family plans or speak to while working in another app. Meeting help is where it currently moves first; for the rest of your day, just ask.
          </p>
        </motion.div>
        <div className="xl:col-span-7 border-l border-border/70 ml-5 sm:ml-7">
          {moments.map((moment, index) => (
            <motion.div {...fadeUp(index * 0.1)} key={moment.title} className="relative pl-10 sm:pl-14 pb-20 last:pb-0">
              <div className="absolute -left-6 top-0 bg-background rounded-full p-2">
                <Orb state={moment.orb} size={33} />
              </div>
              <span className="text-xs text-muted-foreground uppercase tracking-caption">{moment.time}</span>
              <h3 className="text-2xl sm:text-3xl tracking-title mt-4">{moment.title}</h3>
              <p className="text-muted-foreground leading-relaxed mt-4 max-w-xl">{moment.body}</p>
              {index === 3 && (
                <div className="liquid-glass rounded-2xl border border-border/40 p-5 sm:p-6 mt-8 max-w-md">
                  <p className="text-xs text-muted-foreground uppercase tracking-caption">The promise, carried through</p>
                  <p className="text-sm leading-relaxed mt-3">Hi Maya, here&apos;s the deck we discussed. I&apos;ve included the next steps from today&apos;s meeting, too.</p>
                  <div className="flex gap-2 mt-5 text-xs">
                    <span className="rounded-full bg-foreground text-background px-4 py-2">Approve</span>
                    <span className="rounded-full border border-border px-4 py-2">Edit first</span>
                  </div>
                </div>
              )}
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
