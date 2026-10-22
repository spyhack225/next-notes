import { useCallback, useEffect, useRef, useState } from "react";
import { motion, useInView, useReducedMotion } from "framer-motion";
import { ArrowDown, Mic2, Pause, Play, RotateCcw } from "lucide-react";
import { BorderBeam } from "border-beam";
import { VoiceBeam } from "voice-glow";
import { getTheme, subscribeTheme, type Theme } from "../lib/theme";
import Orb from "../components/Orb";
import StatusPill, { type Availability } from "../components/StatusPill";
import type { OrbState } from "../components/orbGeometry";
import GetItOnMac from "../components/GetItOnMac";
import { PERSONA_HEADLINE } from "../lib/personas";
import { fadeUp } from "../lib/motion";

type HeroScene = {
  name: string;
  role: string;
  badge: string;
  orb: OrbState;
  workingOrb: OrbState;
  heading: string;
  status: string;
  working: string;
  acknowledged: string;
  firstLabel: string;
  firstText: string;
  secondLabel: string;
  secondText: string;
  secondDetail?: string;
  /** The assistant speaks first: the opening line is its own, with a yes/no choice. */
  proactive?: { label: string; yes: string; no: string; started: string };
  /** Something it can't take back: shown in full and held until the person approves. */
  approval?: { text: string; done: string };
  footer: string;
  /** Honest status of what this card shows: works today, being built, or planned. */
  availability: Availability;
};

/** Typing speed for the demo, and how long each finished beat is held before the next. */
const TYPING_MS = 34;
const BEAT_MS = { afterTyping: 1000, choice: 1500, acknowledged: 1400, working: 1600, approval: 2600, approved: 1500, scene: 3200 } as const;

/**
 * Three moments, each named by the person it's for. The Catch-up leads because it is the
 * clearest picture of an assistant that is already on it. Every scene plays to its end and
 * is held for a few seconds before the next one starts.
 */
const heroScenes: HeroScene[] = [
  {
    name: "Catch-up",
    role: "Your Monday catch-up",
    availability: "progress",
    badge: "At home, 7 a.m.",
    orb: "composing",
    workingOrb: "composing",
    heading: "While you were out",
    status: "7:00 a.m.",
    working: "Writing to the coach",
    acknowledged: "On it",
    firstLabel: "Next Notes",
    firstText: "Morning. Over the weekend the school sent a permission slip, due Wednesday. I've filled in what I could. Soccer moved to 5. Want me to send the reminder to the coach?",
    secondLabel: "Next Notes",
    secondText: "Here's exactly what I'll send. Nothing goes until you say so.",
    proactive: { label: "Your Monday catch-up", yes: "Go ahead", no: "Not yet", started: "On it." },
    approval: { text: "Hi Coach, just confirming we'll be at the new 5:00 start. See you there!", done: "Sent to the coach ✓" },
    footer: PERSONA_HEADLINE.household,
  },
  {
    name: "Office",
    role: "Keeps up with you",
    availability: "progress",
    badge: "At the office",
    orb: "listening",
    workingOrb: "composing",
    heading: "A new hire",
    status: "Listening",
    working: "Updating the draft",
    acknowledged: "Heard the change",
    firstLabel: "You say",
    firstText: "Draft Sam's welcome email for Friday. Actually, make it Monday.",
    secondLabel: "Next Notes",
    secondText: "Monday it is. Start time, parking and who to ask for are in the draft.",
    secondDetail: "Changed while you were still talking.",
    footer: PERSONA_HEADLINE.office,
  },
  {
    name: "Cases",
    role: "Already on it",
    availability: "progress",
    badge: "Case deadlines",
    orb: "searching",
    workingOrb: "searching",
    heading: "Before you ask",
    status: "Just now",
    working: "Writing to Dana and Luis",
    acknowledged: "On it",
    firstLabel: "Next Notes",
    firstText: "Hartley's filing is Friday, and Dana and Luis still haven't signed. Want me to nudge them?",
    secondLabel: "Next Notes",
    secondText: "Kept it friendly. One note each, ready when you are.",
    proactive: { label: "Next Notes · Already on it", yes: "Nudge them", no: "Not now", started: "On it." },
    approval: { text: "Hi Dana, just a friendly nudge: we still need your signature by Thursday.", done: "Sent to Dana and Luis ✓" },
    footer: PERSONA_HEADLINE.practice,
  },
];

/**
 * Types its text while `running`, holds still when paused or off-screen, and says when it
 * has finished so the scene can wait for the last character instead of guessing a time.
 */
function TypedText({ text, running, onDone }: { text: string; running: boolean; onDone: () => void }) {
  const [visible, setVisible] = useState(0);
  const doneRef = useRef(onDone);
  doneRef.current = onDone;
  const finished = visible >= text.length;

  useEffect(() => {
    if (!running || finished) return;
    const timer = window.setInterval(() => {
      setVisible((count) => Math.min(count + 1, text.length));
    }, TYPING_MS);
    return () => window.clearInterval(timer);
  }, [running, finished, text]);

  useEffect(() => {
    if (finished) doneRef.current();
  }, [finished]);

  return (
    <>
      <span className="sr-only">{text}</span>
      <span aria-hidden="true">
        {text.slice(0, visible)}
        {!finished && <span className="inline-block w-0.5 h-4 ml-0.5 align-middle bg-foreground animate-pulse" />}
      </span>
    </>
  );
}

/** Three moments, one person each, with manual controls and a quiet automatic loop. */
export default function Hero() {
  const carouselRef = useRef<HTMLDivElement>(null);
  const isInView = useInView(carouselRef, { amount: 0.2 });
  const [active, setActive] = useState(0);
  const [phase, setPhase] = useState(0);
  /** True once the text typed in the current phase has reached its last character. */
  const [typed, setTyped] = useState(false);
  const [paused, setPaused] = useState(false);
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  const [take, setTake] = useState(0);
  const reduceMotion = useReducedMotion();
  const scene = heroScenes[active];
  const needsApproval = scene.approval !== undefined;
  const proactive = scene.proactive;
  const lastPhase = needsApproval ? 6 : 4;
  const visiblePhase = reduceMotion ? lastPhase : phase;
  const [theme, setTheme] = useState<Theme>(getTheme);
  /** Someone is pointing at or keyboarding through the demo: it waits for them. */
  const holding = paused || hovered || focused;
  const running = isInView && !holding && !reduceMotion;
  /** The choice buttons appear only once the question has been typed out in full. */
  const choicesReady = reduceMotion || visiblePhase >= 1 || typed;

  useEffect(() => subscribeTheme(setTheme), []);

  /**
   * Demo mic level for the voice glow: a gentle shimmer while the scene is
   * "speaking" (phases 0-1), silence otherwise. Read per frame through a ref
   * so the demo never re-renders for it.
   */
  const liveRef = useRef({ phase: 0, paused: false, inView: false });
  liveRef.current = { phase: visiblePhase, paused: holding, inView: isInView };
  const voiceLevel = useCallback(() => {
    const s = liveRef.current;
    if (!s.inView || s.paused || s.phase > 1) return 0;
    const t = performance.now() / 1000;
    return 0.45 + 0.3 * Math.sin(t * 6.3) * Math.sin(t * 1.7 + 1.2);
  }, []);

  const markTyped = useCallback(() => setTyped(true), []);

  /**
   * Each beat waits for the one before it: typed phases (0 and 3) wait for their last
   * character, then every phase is held a moment, and a finished scene is held for a few
   * seconds before the next one starts. Nothing advances while someone is hovering,
   * focused, paused or looking elsewhere.
   */
  useEffect(() => {
    if (!running) return;
    const isTypedPhase = phase === 0 || phase === 3;
    if (isTypedPhase && !typed) return;
    const hold =
      phase === lastPhase
        ? BEAT_MS.scene
        : phase === 0
          ? proactive ? BEAT_MS.choice : BEAT_MS.afterTyping
          : phase === 1
            ? BEAT_MS.acknowledged
            : phase === 2
              ? BEAT_MS.working
              : phase === 3
                ? BEAT_MS.afterTyping
                : phase === 4
                  ? BEAT_MS.approval
                  : BEAT_MS.approved;
    const timer = window.setTimeout(() => {
      setTyped(false);
      if (phase < lastPhase) {
        setPhase(phase + 1);
      } else {
        setActive((current) => (current + 1) % heroScenes.length);
        setPhase(0);
      }
    }, hold);
    return () => window.clearTimeout(timer);
  }, [lastPhase, phase, proactive, running, typed]);

  function chooseScene(index: number) {
    setActive(index);
    setPhase(0);
    setTyped(false);
    setTake((current) => current + 1);
    setPaused(false);
  }

  return (
    <section id="top" className="relative overflow-hidden px-6 pt-24 pb-12 sm:px-8 md:px-16 lg:px-28 flex items-center">
      <div className="absolute inset-0 flex items-center justify-center pointer-events-none opacity-20" aria-hidden="true">
        <div className="scale-hero-backdrop sm:scale-hero-backdrop-lg md:scale-100">
          <Orb state="breathing" size={640} />
        </div>
      </div>

      <div className="relative z-10 w-full max-w-7xl mx-auto grid xl:grid-cols-2 gap-16 xl:gap-20 items-center">
        <div>
          <motion.p {...fadeUp(0)} className="text-xs uppercase tracking-eyebrow text-muted-foreground mb-7">
            Someone in your corner, on your Mac
          </motion.p>
          <motion.h1 {...fadeUp(0.08)} className="text-5xl sm:text-6xl lg:text-7xl xl:text-8xl font-medium tracking-display leading-display max-w-3xl">
            It&apos;s already on it. <span className="font-serif italic font-normal">Before you even ask.</span>
          </motion.h1>
          <motion.p {...fadeUp(0.18)} className="text-lg sm:text-xl leading-relaxed text-hero-subtitle max-w-xl mt-8">
            It knows your week, your people and what&apos;s coming. Say what&apos;s on your mind, out loud, and it takes it from there, with anything it can&apos;t undo held for your OK. So you get to be there for the parts that matter.
          </motion.p>
          <motion.div {...fadeUp(0.28)} className="flex flex-wrap items-center gap-5 mt-10">
            <GetItOnMac />
            <a href="#who" className="inline-flex items-center gap-2 text-sm text-foreground/80 hover:text-foreground transition-colors">
              See who it&apos;s for <ArrowDown size={16} aria-hidden="true" />
            </a>
          </motion.div>
          <motion.p {...fadeUp(0.38)} className="mt-7 text-sm text-muted-foreground">
            In development, with what works today marked · Any Apple-silicon Mac · Needs macOS 26
          </motion.p>
        </div>

        <motion.div
          {...fadeUp(0.2)}
          ref={carouselRef}
          className="relative w-full max-w-xl mx-auto xl:mr-0"
          role="region"
          aria-roledescription="carousel"
          aria-label="Next Notes catching you up, at home, at the office, and with case deadlines"
          onMouseEnter={() => setHovered(true)}
          onMouseLeave={() => setHovered(false)}
          onFocus={(event) => { if (event.target.matches(":focus-visible")) setFocused(true); }}
          onBlur={(event) => { if (!event.currentTarget.contains(event.relatedTarget)) setFocused(false); }}
        >
          <div className="absolute -top-14 left-1/2 -translate-x-1/2 z-20 whitespace-nowrap" aria-hidden="true">
            <div className="liquid-glass rounded-full px-4 py-2 flex items-center gap-2 shadow-lg">
              <Orb state={scene.orb} size={25} />
              <span className="text-xs">{scene.role} · {scene.badge}</span>
            </div>
          </div>
          <BorderBeam size="md" colorVariant="colorful" strength={0.7} theme={theme} active={running}>
          <div className="liquid-glass rounded-3xl p-5 sm:p-8 border border-border/40 shadow-2xl min-h-128">
              <div className="flex items-center justify-between gap-3 pb-4">
                <span className="flex items-center gap-2 text-xs text-muted-foreground"><Orb state="breathing" size={25} className="shrink-0" /> Next Notes, on this Mac</span>
                <StatusPill status={scene.availability} variant="quiet" />
              </div>
              <motion.div
                key={`${scene.name}-${take}`}
                id="hero-use-case"
                aria-live="off"
                initial={reduceMotion ? false : { opacity: 0.45 }}
                animate={{ opacity: 1 }}
                transition={{ duration: reduceMotion ? 0 : 0.4, ease: "easeOut" }}
                className="flex flex-col min-h-160 sm:min-h-144"
              >
                <div className="flex items-center justify-between gap-3 text-xs text-muted-foreground border-b border-border/60 pb-5">
                  <span className="uppercase tracking-caption">{scene.role} / {scene.heading}</span>
                  <span className="flex items-center gap-1.5 whitespace-nowrap">
                    <span className="w-1.5 h-1.5 rounded-full bg-foreground animate-pulse" aria-hidden="true" />
                    {visiblePhase === 0 ? scene.status : visiblePhase === 1 ? scene.acknowledged : visiblePhase === 2 ? "Working on it" : visiblePhase === 3 ? "Replying" : needsApproval && visiblePhase === 4 ? "Needs your approval" : needsApproval && visiblePhase >= 5 ? visiblePhase === 5 ? "You approved" : "Done" : "Ready"}
                  </span>
                </div>
                <div className="flex-1 flex flex-col gap-4 pt-6">
                  {visiblePhase === 0 && !proactive && (
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
                  {!proactive && visiblePhase >= 1 && (
                    <motion.div initial={reduceMotion ? false : { opacity: 0, x: 18, scale: 0.97 }} animate={{ opacity: 1, x: 0, scale: 1 }} transition={{ duration: 0.4, ease: "easeOut" }} className="self-end max-w-72 rounded-2xl rounded-br-sm bg-secondary p-4 text-sm sm:text-base leading-relaxed">
                      <p className="text-xs text-muted-foreground mb-2">{scene.firstLabel}</p>
                      <p>{scene.firstText}</p>
                      <p className="text-xs text-muted-foreground mt-3 text-right">{scene.acknowledged} ✓</p>
                    </motion.div>
                  )}

                  {proactive && (
                    <motion.div initial={reduceMotion ? false : { opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="self-start w-full rounded-2xl bg-secondary p-4 text-sm sm:text-base leading-relaxed">
                      <p className="text-xs text-muted-foreground mb-2">{proactive.label}</p>
                      <p>{visiblePhase === 0 && !reduceMotion ? <TypedText key={`${scene.name}-${take}-alert`} text={scene.firstText} running={running} onDone={markTyped} /> : scene.firstText}</p>
                      <div className={`flex gap-2 mt-4 text-xs ${choicesReady ? "" : "invisible"}`} aria-hidden={!choicesReady} aria-label="Example choices">
                        <motion.span animate={{ scale: visiblePhase === 1 ? [1, 0.92, 1.04, 1] : 1 }} transition={{ duration: 0.45 }} className="rounded-full bg-foreground text-background px-3 py-1.5">
                          {visiblePhase >= 1 ? `${proactive.yes} ✓` : proactive.yes}
                        </motion.span>
                        <span className="rounded-full border border-border px-3 py-1.5">{proactive.no}</span>
                      </div>
                      <p className={`text-xs text-muted-foreground mt-3 ${visiblePhase >= 1 ? "" : "invisible"}`}>{proactive.started}</p>
                    </motion.div>
                  )}

                  {visiblePhase === 2 && (
                    <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} className="flex items-center gap-3 self-start rounded-2xl border border-border/50 bg-card px-4 py-3 text-sm text-muted-foreground">
                      <Orb state={scene.workingOrb} size={29} />
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
                      <Orb state="composing" size={33} className="shrink-0" />
                      <div className="rounded-2xl rounded-tl-sm bg-card border border-border/50 p-4 text-sm sm:text-base leading-relaxed max-w-sm">
                        <p className="text-xs text-muted-foreground mb-2">{scene.secondLabel}</p>
                        <p>{visiblePhase === 3 && !reduceMotion ? <TypedText key={`${scene.name}-${take}-response`} text={scene.secondText} running={running} onDone={markTyped} /> : scene.secondText}</p>
                        {visiblePhase >= 4 && scene.secondDetail && <p className="mt-3 text-muted-foreground">{scene.secondDetail}</p>}
                      </div>
                    </motion.div>
                  )}

                  {needsApproval && visiblePhase >= 4 && (
                    <motion.div initial={reduceMotion ? false : { opacity: 0, y: 10, scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }} transition={{ duration: 0.45, ease: "easeOut" }} className="ml-10 rounded-2xl border border-border/60 bg-secondary/60 p-4 text-sm">
                      <p className="text-xs text-muted-foreground mb-2">{visiblePhase === 4 ? "Needs your approval" : visiblePhase === 5 ? "You tap Approve" : scene.approval?.done}</p>
                      <p>{scene.approval?.text}</p>
                      {visiblePhase < 6 && (
                        <div className="flex gap-2 mt-4 text-xs">
                          <motion.span animate={{ scale: visiblePhase === 5 ? [1, 0.9, 1.06, 1] : 1 }} transition={{ duration: 0.5 }} className="rounded-full bg-foreground text-background px-3 py-1.5">{visiblePhase === 5 ? "Approved ✓" : "Approve"}</motion.span>
                          <span className="rounded-full border border-border px-3 py-1.5">Edit first</span>
                        </div>
                      )}
                    </motion.div>
                  )}
                </div>

                {!proactive ? (
                  <div className="mt-6 border-t border-border/60 pt-5">
                    <VoiceBeam type="default" level={voiceLevel} processing={visiblePhase === 2} theme={theme} strength={0.7} paused={!running}>
                    <div className="rounded-2xl border border-border/60 bg-card px-4 py-3 flex items-end gap-3 text-sm sm:text-base min-h-16">
                      <div className="flex-1 min-w-0">
                        <p className="text-xs text-muted-foreground mb-1">Just talk</p>
                        <p className={visiblePhase === 0 ? "text-foreground" : "text-muted-foreground"}>
                          {visiblePhase === 0 && !reduceMotion ? <TypedText key={`${scene.name}-${take}-composer`} text={scene.firstText} running={running} onDone={markTyped} /> : visiblePhase === 0 ? scene.firstText : "Listening"}
                        </p>
                      </div>
                      <motion.span animate={{ scale: visiblePhase === 1 ? [1, 0.88, 1.08, 1] : 1 }} transition={{ duration: 0.45 }} className={`w-8 h-8 rounded-full flex items-center justify-center shrink-0 ${visiblePhase === 0 ? "bg-foreground text-background" : "bg-secondary text-muted-foreground"}`} aria-hidden="true">
                        <Mic2 size={15} />
                      </motion.span>
                    </div>
                    </VoiceBeam>
                    {visiblePhase >= lastPhase && <p className="text-xs text-muted-foreground mt-3">{scene.footer}</p>}
                  </div>
                ) : visiblePhase >= lastPhase ? (
                  <p className="text-xs text-muted-foreground mt-6 pt-5 border-t border-border/60">{scene.footer}</p>
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
          </BorderBeam>
        </motion.div>
      </div>
    </section>
  );
}
