import { motion } from "framer-motion";
import { fadeUp } from "../lib/motion";

const features = [
  {
    title: "Talk anywhere",
    body: "Hold one key, say the thing, let go. It lands in the email, the terminal, the doc — wherever the cursor already was. It learns the names and jargon you actually use, so it stops mangling them.",
  },
  {
    title: "Meetings record themselves",
    body: "Speechify sees what's on your calendar and quietly starts when the meeting does. It asks first, and one click skips any meeting you'd rather it stayed out of.",
  },
  {
    title: "Speakers told apart",
    body: "Your microphone and what comes out of your speakers are heard as two separate things, which is how the transcript knows who said what without anything joining the call.",
  },
  {
    title: "Follow-ups you approve",
    body: "It can offer to write the doc, put the follow-up on the calendar, or send the mail. Every one of those waits on a button you press, and shows you the message first.",
  },
];

export default function WhatItDoes() {
  return (
    <section
      id="how-it-works"
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
          Two things, done{" "}
          <span className="font-serif italic font-normal">properly.</span>
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

        <div id="meetings" className="grid md:grid-cols-4 gap-8 mt-24 scroll-mt-28">
          {features.map((feature, i) => (
            <motion.div key={feature.title} {...fadeUp(0.08 * i)}>
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
