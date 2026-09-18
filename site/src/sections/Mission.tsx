import { useRef } from "react";
import { motion, useScroll, useTransform, type MotionValue } from "framer-motion";
import Orb from "../components/Orb";

const PARAGRAPH_ONE =
  "Most of what you need an agent for is already on the machine in front of you. Your files. Your calendar. The names you say every day. A model that can run without leaving the desk.";

const PARAGRAPH_TWO =
  "Your Mac is your best personal assistant. Hold a key. Ask it the rest. It knows you — and everything you say stays here.";

/** The words carrying the argument stay white; everything else settles a shade back. */
const HIGHLIGHTS = new Set(["already", "machine", "files", "calendar", "names", "knows", "stays"]);

const strip = (word: string) => word.replace(/[^A-Za-z-]/g, "").toLowerCase();

function Word({
  word,
  progress,
  range,
  highlighted,
}: {
  word: string;
  progress: MotionValue<number>;
  range: [number, number];
  highlighted: boolean;
}) {
  const opacity = useTransform(progress, range, [0.15, 1]);
  return (
    <span className="relative inline-block mr-[0.25em]">
      <motion.span
        style={{
          opacity,
          color: highlighted ? "hsl(var(--foreground))" : "hsl(var(--hero-subtitle))",
        }}
      >
        {word}
      </motion.span>
    </span>
  );
}

function RevealParagraph({
  text,
  progress,
  start,
  end,
  className,
  highlight,
}: {
  text: string;
  progress: MotionValue<number>;
  start: number;
  end: number;
  className: string;
  highlight: boolean;
}) {
  const words = text.split(" ");
  const span = (end - start) / words.length;
  return (
    <p className={className}>
      {words.map((word, i) => (
        <Word
          key={`${word}-${i}`}
          word={word}
          progress={progress}
          range={[start + i * span, start + (i + 1) * span]}
          highlighted={highlight && HIGHLIGHTS.has(strip(word))}
        />
      ))}
    </p>
  );
}

export default function Mission() {
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ["start 0.85", "end 0.4"],
  });

  return (
    <section ref={ref} className="pt-0 pb-32 md:pb-44 px-8 md:px-28 relative overflow-hidden">
      <div
        className="flex justify-center pointer-events-none select-none"
        aria-hidden="true"
      >
        {/* Present and idle — waiting on you, on purpose. */}
        <div className="scale-[0.75] sm:scale-90 md:scale-100">
          <Orb state="breathing" size={420} />
        </div>
      </div>

      <div className="max-w-5xl mx-auto text-center mt-4">
        <RevealParagraph
          text={PARAGRAPH_ONE}
          progress={scrollYProgress}
          start={0}
          end={0.7}
          highlight
          className="text-2xl md:text-4xl lg:text-5xl font-medium tracking-[-1px] leading-[1.25]"
        />
        <RevealParagraph
          text={PARAGRAPH_TWO}
          progress={scrollYProgress}
          start={0.65}
          end={1}
          highlight={false}
          className="text-xl md:text-2xl lg:text-3xl font-medium mt-10 leading-[1.35]"
        />
      </div>
    </section>
  );
}
