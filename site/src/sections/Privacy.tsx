import { motion } from "framer-motion";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp } from "../lib/motion";

/**
 * One orb per place, in the app's own vocabulary: the machine works to turn audio into
 * words, writes the notes, then the shape settles into a folder on disk.
 */
const places: { title: string; body: string; orb: OrbState }[] = [
  {
    orb: "working",
    title: "Transcribed here",
    body: "Apple's on-device speech recogniser, or Parakeet through CoreML. The audio is turned into words by the machine it was spoken to.",
  },
  {
    orb: "composing",
    title: "Written here",
    body: "A local model reads the transcript and writes the summary, the decisions and who owes what. It is downloaded once and runs offline.",
  },
  {
    orb: "shaping",
    title: "Stored here",
    body: "One folder per meeting in Application Support. Recordings are deleted once the notes are written, unless you ask to keep them.",
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
          Speechify does the listening, the transcribing and the writing on the Mac in front
          of you. No account, no subscription, and no bot joining your call to take notes on
          everyone's behalf.
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
