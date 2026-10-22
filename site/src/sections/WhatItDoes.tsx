import { useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { Mic2 } from "lucide-react";
import Orb from "../components/Orb";
import type { OrbState } from "../components/orbGeometry";
import StatusPill, { AVAILABILITY_MEANING, AVAILABILITY_ORDER, type Availability } from "../components/StatusPill";
import { fadeUp } from "../lib/motion";
import { PERSONA_HEADLINE } from "../lib/personas";

/**
 * The four people the app is for, and the whole picture of what it is being built to do
 * for each of them. Each has ONE outcome headline (`PERSONA_HEADLINE`), used on the list
 * card and in the detail. The detail keeps only: the headline, what keeps them up, one
 * example exchange, the catch-up line and the whole picture. The vision list sells the
 * full dream and labels every line with its honest status, so nothing planned reads as
 * shipped. The example exchange carries its own status too.
 */
const scenes: {
  label: string;
  role: string;
  context: string;
  title: string;
  worry: string;
  vision: { text: string; status: Availability }[];
  /** A one-line example of this person's spoken catch-up: when it plays, and what it says. */
  catchUp: { when: string; line: string };
  ask: string;
  answer: string;
  askStatus: Availability;
  orb: OrbState;
}[] = [
  {
    label: "The household",
    role: "The parent running it all",
    context: "School, practice, forms, the calendar",
    title: PERSONA_HEADLINE.household,
    worry: "The forgotten form. The missed pickup. The bill nobody paid.",
    vision: [
      { text: "Answers about the family calendar and your email, and drafts the reply for your OK.", status: "now" },
      { text: "Sees the clash, the form or the payment coming, and has it handled before you ask.", status: "progress" },
      { text: "Works with the Apple Calendar and Reminders the whole family already shares.", status: "soon" },
      { text: "Keeps track of the forms and bills coming due, and asks before anything is paid.", status: "soon" },
    ],
    ask: "Can we fit soccer and the dentist in on Thursday?",
    answer: "Not both. Practice is at 4:00 and the dentist is 4:15 across town. Friday at 3:30 is open for both.",
    askStatus: "now",
    catchUp: {
      when: "Monday, 7 a.m.",
      line: "Morning. Over the weekend the school sent a permission slip, due Wednesday. I've filled in what I could. Soccer moved to 5. Want me to send the reminder to the coach?",
    },
    orb: "searching",
  },
  {
    label: "The office",
    role: "The office manager",
    context: "New people, the team calendar, the inbox",
    title: PERSONA_HEADLINE.office,
    worry: "Sending the wrong thing to the wrong person. Or the follow-up that never went out.",
    vision: [
      { text: "Tells you what in your inbox needs you, and drafts the replies for your OK.", status: "now" },
      { text: "Records the meeting and writes up the notes, decisions and who owns what.", status: "now" },
      { text: "Gets your new person settled before day one: welcome note, calendar and reminders.", status: "progress" },
      { text: "Remembers what everyone promised, and gently follows up before anyone has to ask.", status: "soon" },
    ],
    ask: "Sam starts Monday. Get everything ready.",
    answer: "Welcome email, desk setup reminder and a first-week calendar are drafted. Nothing sends until you approve.",
    askStatus: "progress",
    catchUp: {
      when: "Monday, 8:30",
      line: "Morning. Sam starts today, and the welcome note you approved went out Friday. Priya's out sick, so her 10:00 needs a new time. Three people are waiting on you. Want me to draft the replies?",
    },
    orb: "composing",
  },
  {
    label: "The practice",
    role: "The person who keeps a law office running",
    context: "Many cases, every deadline, shared files",
    title: PERSONA_HEADLINE.practice,
    worry: "A deadline that slips by. The file nobody can find.",
    vision: [
      { text: "Reads your mail and calendar and tells you what's due when you ask.", status: "now" },
      { text: "Knows every case's dates by heart, so you never have to hunt for one.", status: "progress" },
      { text: "Spots what's slipping, like a missing signature, and drafts the chase for your OK.", status: "progress" },
      { text: "Keeps track of every case's shared files, wherever they live.", status: "soon" },
    ],
    ask: "What's due across all our cases this week?",
    answer: "Three filings: Hartley on Tuesday, Ruiz and Okafor on Friday. The Ruiz exhibits folder hasn't changed in a month.",
    askStatus: "progress",
    catchUp: {
      when: "Back from a long weekend",
      line: "Welcome back. Ruiz's exhibits are due Thursday, and Luis still hasn't signed. Okafor's hearing moved to the 14th; the calendar change is ready for your OK. Want me to nudge Luis?",
    },
    orb: "searching",
  },
  {
    label: "The edit",
    role: "The filmmaker and editor",
    context: "Footage, shoot days, drives",
    title: PERSONA_HEADLINE.edit,
    worry: "A lost clip. A backup that quietly doesn't match.",
    vision: [
      { text: "Say your shot notes and labels, and they're typed for you, hands still on the timeline.", status: "now" },
      { text: "Sorts every card by shoot date, session and drive as it comes in.", status: "soon" },
      { text: "Checks every backup against the original, so you know both drives match.", status: "soon" },
      { text: "Reorganizes when the plan changes, and asks before moving anything.", status: "soon" },
    ],
    ask: "Sort today's cards by shoot day and copy them to both drives.",
    answer: "Two shoot days, four sessions. Here's the folder plan. I'll copy once you approve.",
    askStatus: "soon",
    catchUp: {
      when: "The morning after a shoot",
      line: "Morning. Yesterday's shot notes are typed up, and Thursday's call sheet came in: you're at the warehouse at 7. Want me to remind the crew?",
    },
    orb: "searching",
  },
];

export default function WhatItDoes() {
  const [active, setActive] = useState(0);
  const scene = scenes[active];

  return (
    <section id="who" className="px-6 sm:px-8 md:px-16 lg:px-28 py-16 md:py-24 border-t border-border/40 scroll-mt-16">
      <div className="max-w-7xl mx-auto">
        <motion.div {...fadeUp(0)}>
          <div className="max-w-3xl">
            <p className="text-xs uppercase tracking-eyebrow text-muted-foreground">Who it&apos;s for, and where it&apos;s headed</p>
            <h2 className="text-4xl sm:text-5xl lg:text-6xl tracking-section leading-section mt-5">
              Off your plate, <span className="font-serif italic">before it&apos;s on your mind.</span>
            </h2>
            <p className="text-lg text-muted-foreground leading-relaxed mt-6 max-w-2xl">
              For the people everyone else counts on, who don&apos;t have a weekend to learn a new tool. Here&apos;s everything it&apos;s being built to do for you, with every part labelled.
            </p>
          </div>
          <ul className="flex flex-wrap gap-x-6 gap-y-3 mt-8 text-sm text-muted-foreground" aria-label="What the labels mean">
            {AVAILABILITY_ORDER.map((status) => (
              <li key={status} className="flex items-center gap-2">
                <StatusPill status={status} />
                <span>{AVAILABILITY_MEANING[status]}</span>
              </li>
            ))}
          </ul>
        </motion.div>

        <div className="grid xl:grid-cols-12 gap-8 xl:gap-16 mt-8 md:mt-12 items-start">
          <div className="xl:col-span-4 grid grid-cols-2 xl:flex xl:flex-col gap-3" role="group" aria-label="Choose who it's for">
            {scenes.map((item, index) => (
              <button
                type="button"
                aria-pressed={active === index}
                key={item.label}
                onClick={() => setActive(index)}
                className={`text-left rounded-2xl px-4 py-4 sm:px-6 sm:py-5 border transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground ${active === index ? "border-foreground/40 bg-card" : "border-border/50 hover:border-foreground/30"}`}
              >
                <span className="text-xs text-muted-foreground uppercase tracking-caption">0{index + 1} / {item.label}</span>
                <span className="hidden sm:block text-lg sm:text-xl mt-2 font-medium">{item.role}</span>
                <span className="hidden sm:block text-sm text-muted-foreground mt-2">{item.title}</span>
              </button>
            ))}
          </div>

          <div id="day-scene" role="region" aria-label={`${scene.label}: the whole picture`} className="xl:col-span-8">
            <div className="flex items-start gap-3 pb-5 px-1">
              <Orb state="breathing" size={31} className="shrink-0" />
              <div className="min-w-0 flex-1 sm:flex sm:items-center sm:justify-between sm:gap-4">
                <div className="min-w-0">
                  <p className="text-sm font-medium">Next Notes</p>
                  <p className="text-xs text-muted-foreground">For {scene.role.toLowerCase()}</p>
                </div>
                <span className="block mt-1 text-xs text-muted-foreground sm:mt-0 sm:text-right">On your Mac</span>
              </div>
            </div>
            <AnimatePresence mode="wait">
              <motion.div
                key={scene.label}
                initial={{ opacity: 0, y: 18 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -12 }}
                transition={{ duration: 0.4, ease: "easeOut" }}
                className="liquid-glass rounded-3xl border border-border/40 overflow-hidden"
              >
                <div className="grid md:grid-cols-5">
                  <div className="md:col-span-2 p-6 sm:p-8 flex flex-col justify-center">
                    <div>
                      <p className="text-xs text-muted-foreground uppercase tracking-caption">{scene.context}</p>
                      <h3 className="text-3xl tracking-section leading-section mt-5">{scene.title}</h3>
                      <div className="mt-5 pt-5 border-t border-border/50">
                        <p className="text-xs text-muted-foreground uppercase tracking-caption">What keeps you up</p>
                        <p className="leading-relaxed mt-2">{scene.worry}</p>
                      </div>
                    </div>
                  </div>
                  <div className="md:col-span-3 bg-card/70 border-t md:border-t-0 md:border-l border-border/40 p-6 sm:p-8 flex flex-col justify-center">
                    <div className="flex flex-wrap items-center gap-x-2 gap-y-3 mb-5">
                      <Orb state={scene.orb} size={36} />
                      <span className="text-xs text-muted-foreground uppercase tracking-caption">What it sounds like</span>
                      <StatusPill status={scene.askStatus} className="ml-auto" />
                    </div>
                    <motion.div initial={{ opacity: 0, x: 12 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: 0.22 }} className="self-end max-w-xs bg-secondary rounded-2xl rounded-br-sm p-4 text-sm leading-relaxed">
                      <div className="flex items-center gap-2 text-xs text-muted-foreground mb-2"><Mic2 size={13} aria-hidden="true" /> You say</div>
                      “{scene.ask}”
                    </motion.div>
                    <motion.div initial={{ opacity: 0, x: -12 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: 0.48 }} className="self-start max-w-sm bg-background border border-border/50 rounded-2xl rounded-tl-sm p-4 text-sm leading-relaxed mt-4">
                      <div className="text-xs text-muted-foreground mb-2">Next Notes</div>
                      {scene.answer}
                    </motion.div>
                  </div>
                </div>
                <div className="border-t border-border/40 p-6 sm:p-7 md:px-10">
                  <div className="flex flex-wrap items-center gap-3">
                    <p className="text-xs text-muted-foreground uppercase tracking-caption">Your catch-up · {scene.catchUp.when}</p>
                    <StatusPill status="progress" />
                  </div>
                  <p className="text-lg sm:text-xl leading-relaxed mt-3 max-w-3xl">&ldquo;{scene.catchUp.line}&rdquo;</p>
                </div>
                <div className="border-t border-border/40 p-6 sm:p-7 md:px-10">
                  <p className="text-xs text-muted-foreground uppercase tracking-caption">The whole picture</p>
                  <ul className="grid md:grid-cols-2 gap-x-10 gap-y-4 mt-4">
                    {scene.vision.map((item) => (
                      <li key={item.text} className="flex flex-col items-start gap-2">
                        <StatusPill status={item.status} />
                        <span className="text-sm leading-relaxed">{item.text}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              </motion.div>
            </AnimatePresence>
          </div>
        </div>
      </div>
    </section>
  );
}
