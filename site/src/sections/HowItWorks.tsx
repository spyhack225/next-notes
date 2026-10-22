import { motion } from "framer-motion";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import StatusPill, { type Availability } from "../components/StatusPill";
import { fadeUp } from "../lib/motion";

/**
 * Four steps from what works today to where it's headed. Each leads with what the person
 * gets (title); the small label and the sentence below are the how. Dictation and memory
 * live inside these steps rather than as steps of their own. Every step carries its honest
 * status so the planned parts never read as shipped.
 */
const moments: { time: string; title: string; body: string; orb: OrbState; status: Availability }[] = [
  {
    time: "Say it",
    title: "Say it once, and it's off your mind.",
    body: "Ask about your week or your inbox the way you'd ask someone who knows you, half-finished and mid-thought. Or hold a key and talk into any email: it's typed where you were writing, in your words, without the ums.",
    orb: "listening",
    status: "now",
  },
  {
    time: "Talk it through",
    title: "It keeps up with you, and talks back.",
    body: "It answers while you're still talking, and you can change your mind mid-sentence. It remembers who to copy and that Thursday is early pickup, and you can always see and change what it keeps.",
    orb: "composing",
    status: "progress",
  },
  {
    time: "Catch me up",
    title: "Your catch-up, whenever you want it.",
    body: "In the morning, after a weekend, or whenever you say \u201ccatch me up\u201d: what happened, what needs you, what's coming, and what it already got ready. The meeting about to start, the deadline creeping up, the reply you owe.",
    orb: "searching",
    status: "progress",
  },
  {
    time: "Before anything goes out",
    title: "Nothing goes out without you.",
    body: "An email, a change to your calendar, files copied: anything it can't take back waits for your OK, exactly as it will happen. However much it does for you, that never changes.",
    orb: "breathing",
    status: "now",
  },
];

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="px-6 sm:px-8 md:px-16 lg:px-28 py-16 md:py-24 border-t border-border/40 scroll-mt-16">
      <div className="max-w-7xl mx-auto grid xl:grid-cols-12 gap-14 xl:gap-20">
        <motion.div {...fadeUp(0)} className="xl:col-span-5 xl:sticky xl:top-32 self-start">
          <p className="text-xs uppercase tracking-eyebrow text-muted-foreground">How it works</p>
          <h2 className="text-4xl sm:text-5xl lg:text-6xl tracking-section leading-section mt-6">
            It&apos;s like it <span className="font-serif italic">reads your mind.</span>
          </h2>
          <p className="text-lg text-muted-foreground leading-relaxed mt-7 max-w-lg">
            Four steps, from what works today to where it&apos;s headed. Nothing to set up, nothing to learn.
          </p>
        </motion.div>
        <div className="xl:col-span-7 border-l border-border/70 ml-5 sm:ml-7">
          {moments.map((moment, index) => (
            <motion.div {...fadeUp(index * 0.1)} key={moment.title} className="relative pl-10 sm:pl-14 pb-8 sm:pb-10 last:pb-0">
              <div className="absolute -left-6 top-0 bg-background rounded-full p-2">
                <Orb state={moment.orb} size={33} />
              </div>
              <div className="flex flex-wrap items-center gap-3">
                <span className="text-xs text-muted-foreground uppercase tracking-caption">{moment.time}</span>
                <StatusPill status={moment.status} />
              </div>
              <h3 className="text-2xl sm:text-3xl tracking-title mt-3">{moment.title}</h3>
              <p className="text-muted-foreground leading-relaxed mt-3 max-w-xl">{moment.body}</p>
              {index === moments.length - 1 && (
                <div className="liquid-glass rounded-2xl border border-border/40 p-4 sm:p-5 mt-5 max-w-md">
                  <p className="text-xs text-muted-foreground uppercase tracking-caption">Waiting for your OK</p>
                  <p className="text-sm leading-relaxed mt-3">Hi Sam, welcome aboard! Your first day is Monday at 9:00. Ask for Priya at the front desk.</p>
                  <div className="flex gap-2 mt-4 text-xs">
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
