import { useEffect, useRef, useState } from "react";
import { motion, useInView, useReducedMotion } from "framer-motion";
import { ArrowDown, ArrowUp, ArrowUpRight, Mic2, Pause, Play, RotateCcw } from "lucide-react";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import { fadeUp, DOWNLOAD_URL } from "../lib/motion";

const heroScenes: {
  name: string;
  role: string;
  badge: string;
  orb: OrbState;
  heading: string;
  status: string;
  working: string;
  acknowledged: string;
  firstLabel: string;
  firstText: string;
  secondLabel: string;
  secondText: string;
  secondDetail?: string;
  footer: string;
}[] = [
  {
    name: "Home",
    role: "Home helper",
    badge: "Helping with family plans",
    orb: "searching",
    heading: "The plan at home",
    status: "When you ask",
    working: "Checking your calendar",
    acknowledged: "Message sent",
    firstLabel: "On your mind",
    firstText: "Do I have time to pick up the kids after work?",
    secondLabel: "Next Notes",
    secondText: "Your last meeting ends at 3:30. The rest of the afternoon is clear.",
    secondDetail: "Now you can make the plan and get back to your family.",
    footer: "A plan made. One less thing to carry.",
  },
  {
    name: "Work",
    role: "Office associate",
    badge: "Helping where you work",
    orb: "listening",
    heading: "Right where you work",
    status: "One key away",
    working: "Writing in your app",
    acknowledged: "Your words heard",
    firstLabel: "You say",
    firstText: "Thursday works for me. Could you send over the agenda beforehand?",
    secondLabel: "Typed where your cursor was",
    secondText: "Thursday works for me. Could you send over the agenda beforehand?",
    secondDetail: "No new window. No broken train of thought.",
    footer: "The reply is ready. Stay with your work.",
  },
  {
    name: "Mac apps",
    role: "Office associate",
    badge: "Helping across your Mac",
    orb: "working",
    heading: "Across your Mac",
    status: "When you ask",
    working: "Checking Notes",
    acknowledged: "Request sent",
    firstLabel: "You ask",
    firstText: "Put the decisions from that meeting in Notes for me.",
    secondLabel: "Next Notes",
    secondText: "I found the meeting decisions and can add them to Notes.",
    secondDetail: "Here's what I'd write. You can check it first.",
    footer: "Added to Notes after you approved it.",
  },
  {
    name: "Meeting",
    role: "Meeting partner",
    badge: "Ready before the meeting",
    orb: "searching",
    heading: "Your next meeting",
    status: "Coming up",
    working: "Keeping the conversation",
    acknowledged: "You chose Record now",
    firstLabel: "Before the call",
    firstText: "Your team meeting starts soon. Next Notes is ready to take notes if you want it to.",
    secondLabel: "After the meeting",
    secondText: "You promised Maya the deck. It’s in the notes.",
    secondDetail: "A follow-up is ready for your review.",
    footer: "The work is visible. The choice is yours.",
  },
];

function TypedText({ text, animate }: { text: string; animate: boolean }) {
  const [visible, setVisible] = useState(0);

  useEffect(() => {
    if (!animate) return;
    const timer = window.setInterval(() => {
      setVisible((count) => Math.min(count + 1, text.length));
    }, 46);
    return () => window.clearInterval(timer);
  }, [animate, text]);

  return (
    <>
      <span className="sr-only">{text}</span>
      <span aria-hidden="true">
        {text.slice(0, animate ? visible : text.length)}
        {animate && visible < text.length && <span className="inline-block w-0.5 h-4 ml-0.5 align-middle bg-foreground animate-pulse" />}
      </span>
    </>
  );
}

/** Four concrete moments from the app, with manual controls and a quiet automatic loop. */
export default function Hero() {
  const carouselRef = useRef<HTMLDivElement>(null);
  const isInView = useInView(carouselRef, { amount: 0.2 });
  const [active, setActive] = useState(0);
  const [phase, setPhase] = useState(0);
  const [paused, setPaused] = useState(false);
  const [take, setTake] = useState(0);
  const reduceMotion = useReducedMotion();
  const scene = heroScenes[active];
  const needsApproval = scene.name === "Meeting" || scene.name === "Mac apps";
  const lastPhase = needsApproval ? 6 : 4;
  const visiblePhase = reduceMotion ? lastPhase : phase;

  useEffect(() => {
    if (paused || reduceMotion || !isInView) return;
    const typingTime = Math.max(3500, Math.min(6500, (phase === 0 ? scene.firstText.length : scene.secondText.length) * 46 + 800));
    const timer = window.setTimeout(() => {
      if (phase < lastPhase) {
        setPhase(phase + 1);
      } else {
        setActive((current) => (current + 1) % heroScenes.length);
        setPhase(0);
      }
    }, phase === 0 || phase === 3 ? typingTime : phase === lastPhase ? 2300 : 1700);
    return () => window.clearTimeout(timer);
  }, [active, isInView, lastPhase, paused, phase, reduceMotion, scene.firstText.length, scene.secondText.length]);

  function chooseScene(index: number) {
    setActive(index);
    setPhase(0);
    setTake((current) => current + 1);
    setPaused(false);
  }

  return (
    <section id="top" className="relative min-h-screen overflow-hidden px-6 pt-32 pb-20 sm:px-8 md:px-16 lg:px-28 flex items-center">
      <div className="absolute inset-0 flex items-center justify-center pointer-events-none opacity-20" aria-hidden="true">
        <div className="scale-hero-backdrop sm:scale-hero-backdrop-lg md:scale-100">
          <Orb state="breathing" size={640} />
        </div>
      </div>

      <div className="relative z-10 w-full max-w-7xl mx-auto grid xl:grid-cols-2 gap-16 xl:gap-20 items-center">
        <div>
          <motion.p {...fadeUp(0)} className="text-xs uppercase tracking-eyebrow text-muted-foreground mb-7">
            One familiar companion, starting on your Mac
          </motion.p>
          <motion.h1 {...fadeUp(0.08)} className="text-5xl sm:text-6xl lg:text-7xl xl:text-8xl font-medium tracking-display leading-display max-w-3xl">
            Be present. <span className="font-serif italic font-normal">Keep your promises.</span>
          </motion.h1>
          <motion.p {...fadeUp(0.18)} className="text-lg sm:text-xl leading-relaxed text-hero-subtitle max-w-xl mt-8">
            Next Notes helps with a family plan, a reply at work, and the promise you made in a meeting. It is the same companion through each moment, with your work and your choices close at hand.
          </motion.p>
          <motion.div {...fadeUp(0.28)} className="flex flex-wrap items-center gap-5 mt-10">
            <motion.a href={DOWNLOAD_URL} whileHover={{ y: -3 }} whileTap={{ scale: 0.98 }} className="inline-flex items-center gap-3 bg-foreground text-background rounded-full px-7 py-4 text-sm font-medium">
              Download for Mac <ArrowUpRight size={17} aria-hidden="true" />
            </motion.a>
            <a href="#impact" className="inline-flex items-center gap-2 text-sm text-foreground/80 hover:text-foreground transition-colors">
              See how it helps <ArrowDown size={16} aria-hidden="true" />
            </a>
          </motion.div>
          <motion.p {...fadeUp(0.38)} className="mt-7 text-sm text-muted-foreground">
            Free and open source · macOS 26 · Apple silicon
          </motion.p>
        </div>

        <motion.div
          {...fadeUp(0.2)}
          ref={carouselRef}
          className="relative w-full max-w-xl mx-auto xl:mr-0"
          role="region"
          aria-roledescription="carousel"
          aria-label="Next Notes at home, at work, across your Mac, and in meetings"
        >
          <div className="absolute -top-7 left-1/2 -translate-x-1/2 z-20 whitespace-nowrap" aria-hidden="true">
            <div className="liquid-glass rounded-full px-4 py-2 flex items-center gap-2 shadow-lg">
              <Orb state={scene.orb} size={25} />
              <span className="text-xs">{scene.role} · {scene.badge}</span>
            </div>
          </div>
          <div className="liquid-glass rounded-3xl p-5 sm:p-8 border border-border/40 shadow-2xl min-h-128">
              <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-border/60 pb-5 mb-5">
                <Orb state="breathing" size={35} className="shrink-0" />
                <div className="min-w-0">
                  <p className="text-sm font-medium">Next Notes</p>
                  <p className="text-xs text-muted-foreground">Your companion on this Mac</p>
                </div>
                <span className="w-full pl-12 text-xs text-muted-foreground sm:w-auto sm:pl-0 sm:ml-auto">One place to return</span>
              </div>
              <motion.div
                key={`${scene.name}-${take}`}
                id="hero-use-case"
                aria-live="off"
                initial={reduceMotion ? false : { opacity: 0.45 }}
                animate={{ opacity: 1 }}
                transition={{ duration: reduceMotion ? 0 : 0.4, ease: "easeOut" }}
                className="flex flex-col min-h-104"
              >
                <div className="flex items-center justify-between gap-3 text-xs text-muted-foreground border-b border-border/60 pb-5">
                  <span className="uppercase tracking-caption">{scene.role} / {scene.heading}</span>
                  <span className="flex items-center gap-1.5 whitespace-nowrap">
                    <span className="w-1.5 h-1.5 rounded-full bg-foreground animate-pulse" aria-hidden="true" />
                    {visiblePhase === 0 ? scene.status : visiblePhase === 1 ? scene.acknowledged : visiblePhase === 2 ? "Working on it" : needsApproval && visiblePhase === 4 ? "Needs your approval" : needsApproval && visiblePhase >= 5 ? visiblePhase === 5 ? "You approved" : "Done" : "Ready"}
                  </span>
                </div>
                <div className="flex-1 flex flex-col gap-4 pt-6">
                  {visiblePhase === 0 && scene.name !== "Meeting" && (
                    <motion.div
                      initial={reduceMotion ? false : { opacity: 0 }}
                      animate={{ opacity: 1 }}
                      exit={{ opacity: 0 }}
                      transition={{ duration: 0.4 }}
                      className="flex-1 flex flex-col items-center justify-center gap-3 text-center text-muted-foreground"
                      aria-hidden="true"
                    >
                      <Orb state={scene.orb} size={72} />
                      <span className="text-xs tracking-caption uppercase">Ready when you are</span>
                    </motion.div>
                  )}
                  {scene.name !== "Meeting" && visiblePhase >= 1 && (
                    <motion.div initial={reduceMotion ? false : { opacity: 0, x: 18, scale: 0.97 }} animate={{ opacity: 1, x: 0, scale: 1 }} transition={{ duration: 0.4, ease: "easeOut" }} className="self-end max-w-72 rounded-2xl rounded-br-sm bg-secondary p-4 text-sm sm:text-base leading-relaxed">
                      <p className="text-xs text-muted-foreground mb-2">{scene.firstLabel}</p>
                      <p>{scene.firstText}</p>
                      <p className="text-xs text-muted-foreground mt-3 text-right">{scene.acknowledged} ✓</p>
                    </motion.div>
                  )}

                  {scene.name === "Meeting" && (
                    <motion.div initial={reduceMotion ? false : { opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="self-start w-full rounded-2xl bg-secondary p-4 text-sm sm:text-base leading-relaxed">
                      <p className="text-xs text-muted-foreground mb-2">Next Notes · Before the call</p>
                      <p>{visiblePhase === 0 && !reduceMotion ? <TypedText key="meeting-alert" text={scene.firstText} animate={isInView} /> : scene.firstText}</p>
                      <div className="flex gap-2 mt-4 text-xs" aria-label="Example recording choices">
                        <motion.span animate={{ scale: visiblePhase === 1 ? [1, 0.92, 1.04, 1] : 1 }} transition={{ duration: 0.45 }} className="rounded-full bg-foreground text-background px-3 py-1.5">
                          {visiblePhase >= 1 ? "Record now ✓" : "Record now"}
                        </motion.span>
                        <span className="rounded-full border border-border px-3 py-1.5">Skip</span>
                      </div>
                      {visiblePhase >= 1 && <p className="text-xs text-muted-foreground mt-3">You chose Record now. Recording started.</p>}
                    </motion.div>
                  )}

                  {visiblePhase === 2 && (
                    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="flex items-center gap-3 self-start rounded-2xl border border-border/50 bg-card px-4 py-3 text-sm text-muted-foreground">
                      <Orb state={scene.name === "Meeting" ? "listening" : "working"} size={29} />
                      <span>{scene.working}</span>
                      <span className="flex items-end gap-1 h-4" aria-hidden="true">
                        {[0, 1, 2].map((dot) => (
                          <motion.span key={dot} className="w-1 h-1 rounded-full bg-foreground" animate={{ y: [0, -5, 0] }} transition={{ duration: 0.8, repeat: Infinity, delay: dot * 0.14 }} />
                        ))}
                      </span>
                    </motion.div>
                  )}

                  {visiblePhase >= 3 && (
                    <motion.div initial={reduceMotion ? false : { opacity: 0, y: 10, scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }} transition={{ duration: 0.45, ease: "easeOut" }} className="flex items-start gap-3 self-start w-full">
                      <Orb state={scene.name === "Work" ? "listening" : "composing"} size={33} className="shrink-0" />
                      <div className="rounded-2xl rounded-tl-sm bg-card border border-border/50 p-4 text-sm sm:text-base leading-relaxed max-w-sm">
                        <p className="text-xs text-muted-foreground mb-2">{scene.secondLabel}</p>
                        <p>{visiblePhase === 3 && !reduceMotion ? <TypedText key={`${scene.name}-response`} text={scene.secondText} animate={isInView} /> : scene.secondText}</p>
                        {visiblePhase >= 4 && scene.secondDetail && <p className="mt-3 text-muted-foreground">{scene.secondDetail}</p>}
                      </div>
                    </motion.div>
                  )}

                  {needsApproval && visiblePhase >= 4 && (
                    <motion.div initial={reduceMotion ? false : { opacity: 0, y: 10, scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }} transition={{ duration: 0.45, ease: "easeOut" }} className="ml-10 rounded-2xl border border-border/60 bg-secondary/60 p-4 text-sm">
                      <p className="text-xs text-muted-foreground mb-2">{visiblePhase === 4 ? "Next Notes asks for your approval" : visiblePhase === 5 ? "You tap Approve" : scene.name === "Meeting" ? "Message sent to Maya ✓" : "Added to Notes ✓"}</p>
                      <p>{scene.name === "Meeting" ? "Hi Maya, here's the deck we discussed. I've included the next steps, too." : "Decisions: Maya needs the deck. We will review the plan on Thursday."}</p>
                      {visiblePhase < 6 && (
                        <div className="flex gap-2 mt-4 text-xs">
                          <motion.span animate={{ scale: visiblePhase === 5 ? [1, 0.9, 1.06, 1] : 1 }} transition={{ duration: 0.5 }} className="rounded-full bg-foreground text-background px-3 py-1.5">{visiblePhase === 5 ? "Approved ✓" : "Approve"}</motion.span>
                          <span className="rounded-full border border-border px-3 py-1.5">Edit first</span>
                        </div>
                      )}
                    </motion.div>
                  )}
                </div>

                {scene.name !== "Meeting" ? (
                  <div className="mt-6 border-t border-border/60 pt-5">
                    <div className="rounded-2xl border border-border/60 bg-card px-4 py-3 flex items-end gap-3 text-sm sm:text-base min-h-16">
                      <div className="flex-1 min-w-0">
                        <p className="text-xs text-muted-foreground mb-1">{scene.name === "Work" ? "Hold a key and speak" : "Ask Next Notes"}</p>
                        <p className={visiblePhase === 0 ? "text-foreground" : "text-muted-foreground"}>
                          {visiblePhase === 0 && !reduceMotion ? <TypedText key={`${scene.name}-composer`} text={scene.firstText} animate={isInView} /> : visiblePhase === 0 ? scene.firstText : scene.name === "Work" ? "Ready for your next thought" : "Ask another question"}
                        </p>
                      </div>
                      <motion.span animate={{ scale: visiblePhase === 1 ? [1, 0.88, 1.08, 1] : 1 }} transition={{ duration: 0.45 }} className={`w-8 h-8 rounded-full flex items-center justify-center shrink-0 ${visiblePhase === 0 ? "bg-foreground text-background" : "bg-secondary text-muted-foreground"}`} aria-hidden="true">
                        {scene.name === "Work" ? <Mic2 size={15} /> : <ArrowUp size={16} />}
                      </motion.span>
                    </div>
                    {visiblePhase >= lastPhase && <p className="text-xs text-muted-foreground mt-3">{scene.footer}</p>}
                  </div>
                ) : visiblePhase >= lastPhase ? (
                  <p className="text-xs text-muted-foreground mt-6 pt-5 border-t border-border/60">Sent only after you approved it.</p>
                ) : null}
              </motion.div>
            <div className="flex flex-wrap items-center justify-center gap-2 mt-5" role="group" aria-label="Choose or replay a use case">
              {heroScenes.map((item, index) => (
                <button
                  key={item.name}
                  type="button"
                  aria-pressed={active === index}
                  aria-controls="hero-use-case"
                  onClick={() => chooseScene(index)}
                  className={`min-h-10 rounded-full px-4 text-xs font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground ${active === index ? "bg-foreground text-background" : "text-muted-foreground hover:text-foreground"}`}
                >
                  {item.name}
                </button>
              ))}
              <button
                type="button"
                onClick={() => chooseScene(active)}
                aria-label={`Replay ${scene.name} example`}
                className="min-h-10 rounded-full px-3 text-xs text-muted-foreground hover:text-foreground transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground inline-flex items-center gap-1.5"
              >
                <RotateCcw size={13} aria-hidden="true" /> Replay
              </button>
              {!reduceMotion && (
                <button
                  type="button"
                  onClick={() => setPaused((current) => !current)}
                  aria-label={paused ? "Play use case demo" : "Pause use case demo"}
                  className="min-h-10 rounded-full px-3 text-xs text-muted-foreground hover:text-foreground transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground inline-flex items-center gap-1.5"
                >
                  {paused ? <Play size={13} aria-hidden="true" /> : <Pause size={13} aria-hidden="true" />}
                  {paused ? "Play" : "Pause"}
                </button>
              )}
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}
