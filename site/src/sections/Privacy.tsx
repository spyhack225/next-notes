import { motion } from "framer-motion";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp } from "../lib/motion";

/**
 * One orb per place, in the app's own vocabulary: it remembers you, thinks beside you,
 * and keeps what you said where it started — on your Mac.
 */
const places: { title: string; body: string; orb: OrbState }[] = [
  {
    orb: "shaping",
    title: "It remembers you here",
    body: "Your files, your calendar, the names it has learned, the meetings you kept. The context an agent needs already lives on this Mac — and it stays there.",
  },
  {
    orb: "composing",
    title: "It thinks here",
    body: "Speech recognition and a local model run on the machine that heard you. The listening, the writing and the deciding never leave the desk.",
  },
  {
    orb: "working",
    title: "It keeps you here",
    body: "One folder per meeting in Application Support. Recordings go when the notes are done, unless you ask to keep them. No account. No remote vault.",
  },
];

export default function Privacy() {
  return (
    <section id="privacy" className="pt-52 md:pt-64 pb-6 md:pb-9 px-8 md:px-28">
      <div className="max-w-6xl mx-auto">
        <motion.h2
          {...fadeUp(0)}
          className="text-5xl md:text-7xl lg:text-8xl font-medium tracking-[-2px] text-center leading-[1.02]"
        >
          Every other tool{" "}
          <span className="font-serif italic font-normal">uploads you.</span>
        </motion.h2>

        <motion.p
          {...fadeUp(0.12)}
          className="text-muted-foreground text-lg max-w-2xl mx-auto mb-24 mt-7 text-center leading-relaxed"
        >
          This one does the opposite. Your Mac is the agent — it already has your memory,
          your storage, a model that runs beside you. Everything you say stays local. No
          account, no subscription, and no bot joining your call to take notes on everyone
          else&apos;s behalf.
        </motion.p>

        <div className="grid md:grid-cols-3 gap-12 md:gap-8 mb-20">
          {places.map((place, i) => (
            <motion.div
              key={place.title}
              {...fadeUp(0.1 * i)}
              className="flex flex-col items-center text-center"
            >
              <Orb state={place.orb} size={120} />
              <h3 className="font-semibold text-base mt-6">{place.title}</h3>
              <p className="text-muted-foreground text-sm mt-3 max-w-xs leading-relaxed">
                {place.body}
              </p>
            </motion.div>
          ))}
        </div>

        <motion.p {...fadeUp(0.1)} className="text-muted-foreground text-sm text-center">
          There is no server to send it to.
        </motion.p>
      </div>
    </section>
  );
}
