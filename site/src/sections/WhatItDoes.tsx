import { motion } from "framer-motion";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp } from "../lib/motion";

/**
 * The orb over each card is the app's own binding, not decoration: dictation listens, a
 * meeting braids two tracks into one, diarization is a clustering problem clicking into
 * place, and the agent sweeps your mail and calendar.
 */
const features: { title: string; body: string; orb: OrbState }[] = [
  {
    orb: "listening",
    title: "Talk, in context",
    body: "Hold one key, say the thing, let go. The cleaned-up sentence lands in the email, the terminal, the doc — wherever the cursor already was, even if you wandered off while it was thinking. It writes Markdown where Markdown renders and plain prose where it does not, and it learns the names and jargon you actually use, so it stops mangling them.",
  },
  {
    orb: "weaving",
    title: "Meetings record themselves",
    body: "It reads your calendar and starts when the meeting does, asking first. Your microphone and what comes out of your speakers are heard as two separate tracks, which is how the transcript knows who said what without anything joining the call.",
  },
  {
    orb: "searching",
    title: "Proposes while you talk",
    body: "It can listen for the asks as they happen — send me the deck, let\u2019s meet Thursday — and have the follow-up ready before the call ends. Everything it offers waits on a button you press, and shows you the message in full first.",
  },
  {
    orb: "connecting",
    title: "Into your Google account",
    body: "Once approved, it writes the doc to Drive, puts the event on Calendar and sends the mail from Gmail — running as you, through Google\u2019s own command-line tool, so the app never holds credentials of its own.",
  },
];

export default function WhatItDoes() {
  return (
    <section
      id="features"
      className="py-32 md:py-44 border-t border-border/30 px-8 md:px-28"
    >
      <div className="max-w-6xl mx-auto">
        <motion.p
          {...fadeUp(0)}
          className="text-xs tracking-[3px] uppercase text-muted-foreground text-center"
        >
          What it does
        </motion.p>

        <motion.h2
          {...fadeUp(0.1)}
          className="text-4xl md:text-6xl font-medium tracking-[-1.5px] text-center mt-6 leading-[1.05]"
        >
          Talk. Meet. Then it{" "}
          <span className="font-serif italic font-normal">follows through.</span>
        </motion.h2>

        {/* The whole of the dictation pitch, in the only form that proves it. */}
        <motion.div
          {...fadeUp(0.2)}
          className="liquid-glass rounded-2xl mt-16 p-8 md:p-12 max-w-3xl mx-auto"
        >
          <p className="text-[11px] tracking-[2px] uppercase text-muted-foreground">
            You said
          </p>
          <p className="text-lg md:text-xl mt-3 text-muted-foreground leading-relaxed">
            um so i need to send the report by friday no wait make that thursday
          </p>

          <div className="h-px bg-border/50 my-8" />

          <p className="text-[11px] tracking-[2px] uppercase text-muted-foreground">
            It wrote
          </p>
          <p className="text-lg md:text-xl mt-3 leading-relaxed">
            So I need to send the report by Thursday.
          </p>
        </motion.div>

        <div id="meetings" className="grid md:grid-cols-4 gap-12 md:gap-8 mt-24 scroll-mt-28">
          {features.map((feature, i) => (
            <motion.div key={feature.title} {...fadeUp(0.08 * i)}>
              <Orb state={feature.orb} size={64} className="-ml-1 mb-5" />
              <h3 className="font-semibold text-base">{feature.title}</h3>
              <p className="text-muted-foreground text-sm mt-3 leading-relaxed">
                {feature.body}
              </p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
