import { useRef } from "react";
import { motion, useReducedMotion, useScroll, useTransform, type MotionValue } from "framer-motion";
import Orb from "../components/Orb";

const PARAGRAPH_ONE =
  "Be there for pickup. Be in the meeting. Be the person who follows through.";

const PARAGRAPH_TWO =
  "One familiar companion on your Mac carries the details so you can give more of yourself to the life you are building.";

const HIGHLIGHTS = new Set(["pickup", "meeting", "follows", "through"]);

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
  const reducedMotion = useReducedMotion();
  return (
    <span className="relative inline-block mr-word">
      <motion.span
        className={`mission-word ${highlighted ? "text-foreground" : "text-hero-subtitle"}`}
        style={{ "--word-reveal": reducedMotion ? 1 : opacity } as React.CSSProperties}
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
    <section ref={ref} className="pt-16 md:pt-24 pb-32 md:pb-44 px-6 sm:px-8 md:px-16 lg:px-28 relative overflow-hidden border-t border-border/40">
      <div
        className="flex justify-center pointer-events-none select-none"
        aria-hidden="true"
      >
        <div className="scale-75 sm:scale-90 md:scale-100">
          <Orb state="breathing" size={300} />
        </div>
      </div>

      <div className="max-w-5xl mx-auto text-center mt-6">
        <RevealParagraph
          text={PARAGRAPH_ONE}
          progress={scrollYProgress}
          start={0}
          end={0.7}
          highlight
          className="text-3xl md:text-5xl lg:text-6xl font-medium tracking-headline leading-reveal"
        />
        <RevealParagraph
          text={PARAGRAPH_TWO}
          progress={scrollYProgress}
          start={0.65}
          end={1}
          highlight={false}
          className="text-xl md:text-2xl lg:text-3xl font-medium mt-10 leading-settle"
        />
      </div>
    </section>
  );
}
