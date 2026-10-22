# Who we serve: personas and the ideal customer, written as outcomes

**Owner feedback 2026-10-04:** the four personas are a starting point to expand, not a closed
list. This file describes the people, what they want in their own words, and how the app
should meet them. It sells results, never features. Read `00-README.md` §1, its
"Messaging rules" and its "Voice and personality" sections first. Each person below also has
how the assistant should feel to them and what it sees coming before they ask (owner decision
2026-10-04: personal and anticipatory, never organisational).

Two honesty rules apply to every table below:
- **"Path exists" is not "dependable".** The agent currently scores 3/10 on its fixed quick
  tool set against a 9/10 bar. A job listed as covered means the code path is there, not that a
  person can rely on it yet. Nothing here may be promised in copy until its gate passes
  (AGENT-OVERHAUL X11).
- **Every capability named was checked in code on 2026-10-04.** Where it has never run live
  (for example any Workspace write), the table says so.

---

## 1. The ideal customer in one paragraph

Someone who keeps other people's lives or work running — a family, a team, a caseload, a
production — and is drowning in the coordination: calendars, inboxes, files, deadlines,
money. They are good at their job and not interested in technology for its own sake. They have
tried an AI chat app, maybe liked it, but it did not *do* anything, and setting up "agents"
looked like a weekend project. They worry about sending the wrong thing to the wrong person,
losing a file, missing a date, and about their private or clients' information leaving their
computer. They own a Mac, often not a new or expensive one.

**Shared traits that define the segment**

| Trait | What it means for the app |
|---|---|
| Overloaded, interrupted all day | Answers must arrive while they are still in the moment: voice, fast, no tab-hopping |
| Coordinates people, calendars, files, money | Mail, calendar, files and meetings are the core; everything else is secondary |
| Low tolerance for setup | Nothing to configure before the first useful result; no terminal, key, account form or model choice |
| High cost of a mistake | Every send, share, move, delete or payment shows exactly what will happen and waits for a yes |
| Privacy-sensitive (family, clients, case files, unreleased footage) | Their things stay on their Mac by default; any exception is their explicit choice |
| Often on a modest Mac | It has to be fast on a MacBook Air with 16 GB (see `02-FLOOR-BENCHMARK.md`) |

**Not the customer:** developers, people who want to choose or tune a model, people who want a
fully autonomous agent that acts without asking, and large enterprises buying a platform.

---

## 2. The parent running the household

**A day.** Up before everyone; checks the school app and a mail thread about a field trip
permission slip while making lunches. Drives two kids to two places. At work, a text from the
other parent: "can you do pickup Thursday?" — they cannot remember what Thursday holds. Evening:
groceries for the week, a forgotten dentist bill, a birthday party RSVP, next month's swim sign-up.

**Recurring jobs:** the family calendar (school events, practices, appointments, who drives
whom); school and activity email (forms, deadlines, payments, closures); weekly meal plan and
grocery list; household budget and bills; birthdays, gifts and RSVPs; trip and holiday planning;
medical and dental appointments; car, insurance and home maintenance reminders; coordinating
with a co-parent, grandparents, sitters and other parents.

**Limits.** Minutes, not hours, between other things. Comfortable with a phone, not with
settings. Fears: missing a school deadline or a pickup; replying to the wrong parent group; an
app that needs an evening to learn. Privacy: children's names, schools, health and money — very
sensitive; would not want them in someone else's cloud.

**The dream, in their words.** "Tell me what I'm forgetting before it's a problem." "I just want
one place that knows the whole family's week." "Answer the school email for me — I'll check it
first." "I want to stop being the family's calendar."

**How the app approaches them.**
- *First run:* one dictation and one question about their own week. If their family calendar is
  Apple's, it should work without a Google account (gap, PL-10).
- *How it talks:* "You have pickup at 3:15 and a dentist at 4 — that's tight." Never "event",
  "sync", "integration".
- *Show, don't list:* the first proactive message uses their real week ("Thursday has swim at
  5 and nobody's down for pickup"), never a feature tour.
- *Proactive:* a short morning "today at home"; a nudge when a school email asks for something
  with a date. *Waits:* replying to anyone, adding to a shared calendar, paying anything.
- *Trust:* it shows where every fact came from ("from Ms. Rivera's email on Monday"), drafts
  rather than sends, and never sends to a group without showing the recipients.

**How it should feel to them.** Like the one other adult who actually keeps the family's week
in their head — calm, a little ahead, on their side. Never a school portal, never a to-do app.

**What it sees coming, and how it says so**
- *Patterns in the week:* who drives on which day, the Thursday swim that always collides with a
  late meeting, the Sunday-night lunch packing. → "I noticed Thursdays have been a scramble.
  Want me to keep your four o'clock clear this week?"
- *Recurring deadlines:* term fees, form returns, swim sign-up opening each month. → "Before you
  ask — swim sign-ups open Monday at nine; last term they were full by ten."
- *People's habits:* Grandma prefers a call to a text; the co-parent confirms pickups the night
  before. → "Dan usually confirms Thursday pickup by now — want me to check with him?"
- *Seasonal moments:* back-to-school forms, birthday parties in the same month each year, the
  holiday plan that started in October last year. → "Maya's birthday is in three weeks. Last
  year you booked the party place about now."
- *Quietly prepared:* the reply to the school (drafted, not sent), the weekly plan with clashes
  marked, the grocery list from what was said during the week.

**Jobs mapped to what exists**

| Job | Today in code | Status / gap |
|---|---|---|
| "What's on today / do I have time for…" | Google agenda read (`workspace.get_agenda`); Apple Calendar feeds meeting arming and the "Now" block's next event only | Google reads ran on the owner's account; Apple Calendar is not readable by the agent → **PL-10** |
| School/activity email: find, summarise, draft a reply | `workspace.search_email`, `read_email`, `draft_email`, `reply_email` | Reads ran live; no write ever approved live |
| Add an event | `workspace.create_event` (approval) | Never approved live; Apple Calendar write → **PL-10** |
| Reminders at a time ("remind me Friday to pay swim") | `schedule.create` reminder/routine, quiet hours (`Agent/Schedules/`) | Self-tested; app's own reminders, not Apple Reminders → **PL-10** |
| Grocery list, meal plan | `memory.remember`/`recall`; `workspace.create_doc`/`append_doc` | No list surface a family would use → **PL-10** (Apple Reminders lists) |
| Budget, bills | Nothing reads bank or card data | **Gap, no task** (and must never involve entering financial credentials) |
| Order groceries | `browser.purchase` exists with a per-call spending cap, its own risk class and mandatory approval | Never run against a real store; not part of the default promise |
| Morning plan, nudges | Routines, `DigestTemplate`, trigger events | Persona content → **PL-06** |
| Notice the week's patterns (who drives when, recurring clashes) | Calendar reads, `memory.recall`, knowledge `timeline` (graph off by default) | No pass looks for patterns → **PL-12** |
| Recurring deadlines and seasonal moments ("last year about now…") | `workspace.get_agenda` can read any past date; memory | Nothing compares this year with last → **PL-12** |
| Morning catch-up, "while you were out" | `DigestTemplate`/`PodcastTemplate` routines exist with no offer path | One warm catch-up → **PL-11** |

**Example spoken requests (for PL-05 set H)**
- "Do I have time to pick up the kids at three?"
- "What does the school need from us this week?"
- "Add soccer practice Thursday at five, every week until June."
- "Remind me Sunday night to pack the field-trip lunch."
- "Put milk, eggs and the gluten-free bread on the grocery list."
- "Who's driving to swim on Wednesday?"
- "Reply to the birthday invite and say we'll come, two kids."
- "When is Maya's next dentist appointment?"
- "How much did we spend on groceries this month?" (must answer honestly that it cannot see that)
- "Plan our week — anything clashing?"
- "Catch me up." / "What am I forgetting this week?"

---

## 3. The office manager

**A day.** First in. Clears the overnight inbox: vendor invoices, a facilities issue, three
people asking to move the Tuesday meeting. A new hire starts Monday — laptop, accounts, desk,
welcome lunch, first-week schedule. Afternoon all-hands; they take the notes and owe everyone a
summary. Before leaving, chases two people who still have not sent their expense reports.

**Recurring jobs:** onboarding and offboarding staff; team calendar (rooms, recurring meetings,
holidays, out-of-office); meeting notes and follow-ups; inbox triage and summaries for the boss;
vendor and facilities coordination; supplies and orders; expense and invoice chasing; policies
and shared documents; event planning (offsites, birthdays); answering "where is…" questions.

**Limits.** Constant interruptions; the boss's priorities change hourly. Comfortable with email,
calendar and documents; not with automation tools. Fears: emailing the whole company by mistake;
double-booking the CEO; a follow-up that never went out; a tool IT has to approve. Privacy:
salaries, HR matters, personal details of staff — sensitive and sometimes contractually so.

**The dream, in their words.** "After every meeting, the follow-ups are already written — I just
hit send." "I want Monday's new hire to have a perfect first week without me building it from
scratch." "Tell me what in my inbox actually needs me." "Stop me chasing people."

**How the app approaches them.**
- *First run:* record or arm one real meeting; the first result is their own notes and follow-ups.
- *How it talks:* "Three people need an answer from you today; the rest can wait." "Here are the
  follow-ups from the all-hands — five emails, ready for you to check."
- *Show, don't list:* the moment of value is the post-meeting card built from their meeting.
- *Proactive:* after a meeting, drafted follow-ups; Monday before a start date, the new-hire
  checklist. *Waits:* every email sent, every invite, anything to a list or a group.
- *Trust:* recipients and full text visible before sending; "not sure it went out" is said
  honestly instead of sending twice; quotes the line from the meeting each follow-up came from.

**How it should feel to them.** Like a sharp, warm colleague who was in every meeting and
remembers who promised what — the person who says "already on it" before they are asked.

**What it sees coming, and how it says so**
- *Patterns in the week:* the Monday inbox flood, the Tuesday meeting that always gets moved,
  who never sends expenses on time. → "Tuesday's meeting has moved three weeks running. Want me
  to suggest Wednesday as the new standing time?"
- *Recurring deadlines:* month-end expenses, payroll cut-off, quarterly reviews, licence renewals.
  → "Before you ask — expenses close Friday. Four people haven't sent theirs; the nudges are
  drafted."
- *People's habits:* the boss reads email at seven and decides by nine; a vendor needs two
  reminders. → "Already drafted the summary for Alex — ready for you to send before they check at seven."
- *Seasonal moments:* new hires before the busy season, the holiday party, annual reviews,
  office closures. → "Last year the holiday party venue was booked by mid-October."
- *Quietly prepared:* follow-ups from every meeting (drafted, waiting for a yes), the new hire's
  first-week calendar as a proposal, the "who owes what" list.

**Jobs mapped to what exists**

| Job | Today in code | Status / gap |
|---|---|---|
| Meeting notes, decisions, owed items | Two-track capture, Parakeet, speaker identification, notes; `meeting.decisions`, `meeting.action_items`, `meeting.transcript`, `meeting.search` | Meetings in daily use; agent's meeting reads are part of the low quick score |
| Post-meeting follow-up drafts | `MeetingAgent` proposals, Needle watcher, `workspace.draft_email`/`send_email` | Never approved live; owed-items loop is AGENT-OVERHAUL P4-05/X05 → **PL-06** |
| Inbox summary "what needs me" | `workspace.search_email`, `read_email` | Reads ran live; quality open |
| New-hire first week | `workspace.create_event`, `create_doc`, `schedule.create` | Writes unproven; checklist routine → **PL-06** |
| Team availability | Only the person's own calendar via `gws` | **Gap, no task** (free/busy across a team) |
| Chasing people | Reminders and routines; `send_email` with approval | Nudge content → **PL-06** |
| Shared documents and files | `workspace.find_drive_files`, `upload_to_drive`, `read_doc`, `filesystem.find` | No Drive sharing tool → noted in **PL-07** |
| Google connection without IT/Terminal | Terminal-based `gws` setup today | **PL-09** |
| Notice patterns (meetings that keep moving, people who are always late with expenses) | Calendar and mail reads, meeting history, memory | No pattern pass → **PL-12** |
| Month-end and seasonal deadlines prepared in advance | Routines (`schedule.create`), mail reads | Anticipation → **PL-12**; offers → **PL-06** |
| Monday catch-up for them and for the boss | Digest/podcast templates (no offer path) | **PL-11** |

**Example spoken requests (for PL-05 set W)**
- "What in my inbox needs me today?"
- "Write the follow-ups from this morning's all-hands."
- "Send Jordan the notes and the two things he owes us." (must stop at the approval card)
- "Set up Priya's first week: standup Monday, lunch Tuesday, IT on Monday morning."
- "Move Tuesday's team meeting to Wednesday at ten and tell everyone."
- "Who still hasn't sent their expense report?"
- "Remind me every Friday at four to check the supply order."
- "Is everyone free Thursday afternoon?" (must say honestly what it can and cannot see)
- "What did we decide about the holiday party?"
- "Catch me up on Monday." / "What's coming that I haven't thought about?"

---

## 4. The legal-practice operations manager (not the lawyer)

**A day.** Runs the machinery of a small or mid-size practice: forty open matters, each with
filings, court dates, client documents and opposing counsel. Morning: the deadline calendar.
A partner asks where the signed engagement letter for a new client is. A paralegal is out; their
filings due this week need reassigning. Afternoon: a document needs to go to opposing counsel —
the right version, to the right person, nothing privileged attached.

**Recurring jobs:** deadline and court-date tracking; opening and closing matters (folders,
naming, checklists); finding the latest version of a document; tracking what was shared with whom
and when; client intake paperwork; staff calendars and coverage; meeting notes from case
meetings; billing reminders and follow-ups.

**Limits.** Accuracy over speed; a missed deadline is malpractice risk. Comfortable with the
practice's own systems, wary of new ones. Fears: a wrong attachment or recipient (privilege),
a missed filing date, a misfiled document, client data leaving the firm. Privacy: the highest of
all four — confidentiality obligations; cloud tools often need sign-off.

**The dream, in their words.** "Nothing slips — I see every deadline before it bites." "I can
find the right version of any document in seconds." "I know exactly what went to whom." "It stays
on our machines."

**How the app approaches them.**
- *First run:* point it at the matters folder; the first result is "find the latest … for …"
  answered from their own files, with the file shown.
- *How it talks:* precise and sourced: "The last version is 'Ortiz – Response v4', saved Tuesday
  by you." Never guesses a date or a name.
- *Show, don't list:* "These three matters have something due in the next seven days."
- *Proactive:* weekly deadlines view; nudge days before a calendared deadline. *Waits:* every
  email, every share, every move or rename of a client file.
- *Trust:* "stays on this Mac" is the default and is visible; every claim names its source; an
  uncertain answer says so; nothing leaves without the exact content shown.

**How it should feel to them.** Like a meticulous, discreet second pair of eyes that never
forgets a date and never guesses — reassuring, precise, quietly protective of the practice.

**What it sees coming, and how it says so**
- *Patterns:* which matters go quiet before trouble, which partner asks for which document on
  Mondays. → "I noticed the Henley file hasn't moved in three weeks and a hearing is in five."
- *Recurring deadlines:* filing windows, response periods, renewal dates, billing cycles. →
  "Before you ask — three responses are due next week. The latest drafts are in each folder."
- *People's habits:* a client who always sends documents late; opposing counsel who replies
  Friday evening. → "Mrs. Chen usually sends signed pages a day late — want me to ask today?"
- *Seasonal moments:* year-end billing, court holidays, annual compliance. → "Courts close for
  the holidays in four weeks; two filings would land in that window."
- *Quietly prepared:* a weekly deadlines view, the latest version located for each due item,
  a draft covering note for anything due to go out (never sent, never shared without a yes).

**Jobs mapped to what exists**

| Job | Today in code | Status / gap |
|---|---|---|
| Find the latest document for a matter | `filesystem.find` (name, kind, folder, `modifiedAfter`), `filesystem.tree`, file index with creation dates | Self-tested (`--selftest-file-index`, `--selftest-fs`) |
| Deadlines this week | Google agenda + mail search | Reads ran live; quality open; Apple Calendar → **PL-10** |
| Open a new matter folder, file documents | `filesystem.write`/`move`/`copy` (modify risk, approval each) | One approval per file today → plan + one approval in **PL-07** |
| What was shared with whom | Mail search can find sent mail; no Drive sharing-state read | **Gap** noted in **PL-07** |
| Case meeting notes | Meetings pipeline, meeting tools | In daily use |
| Confidentiality | Local by default; `usage.jsonl` never leaves the Mac; cloud is per-workload opt-in | Proof of boundaries is AGENT-OVERHAUL X10 |
| Notice stalled matters and recurring filing windows | File index dates, calendar and mail reads, meeting notes | No pattern pass → **PL-12** |
| Weekly "what's due" catch-up with the latest version located | Digest template reads calendar, notes and mail; `filesystem.find` is not in its read ceiling | **PL-11** (adding file reads to the ceiling is a decision there) |

**Example spoken requests (for PL-05 set L)**
- "Which matters have a deadline in the next seven days?"
- "Find the latest version of the Ortiz response."
- "Make a folder for the new Henley matter with our usual subfolders." (approval card)
- "Did we send the signed engagement letter to the Chen family?"
- "What did we agree in Tuesday's case meeting about discovery?"
- "Remind me three days before every filing deadline."
- "Has the settlement draft been shared with the other side?" (must say it cannot see sharing)
- "Move everything in Downloads with 'Ortiz' in the name into the Ortiz folder." (a plan, then one yes)
- "Catch me up — what changed on my matters since Friday?"

---

## 5. The filmmaker / editor

**A day.** Two shoot days this week across three cards and two drives. Back in the edit, they
need "the wide shot from Tuesday afternoon" and spend twenty minutes scrubbing folders named
`CARD_002`. The producer emails about delivery dates; a client call needs notes. End of day:
offload, duplicate to the backup drive, and hope both match.

**Recurring jobs:** offloading cards and organising by date, session, camera and location;
keeping a backup drive in step; finding shots and takes; tracking which drive holds which
project; delivery deadlines and client feedback; call notes with producers and clients; invoices
and shoot scheduling.

**Limits.** Deep expertise in their craft, little patience for admin. Fears: losing footage
(irreplaceable), filling a drive mid-offload, a tool that moves files where they cannot find them,
slowing down the edit machine. Privacy: unreleased client work under NDA.

**The dream, in their words.** "Every shoot lands in the right folder by itself." "Find me the
shot, I'll describe it." "Tell me my backup actually matches before I wipe the card." "Don't
touch my edit while I'm working."

**How the app approaches them.**
- *First run:* point it at a footage folder; the first result is "find Tuesday's footage"
  answered from their drives.
- *How it talks:* in their terms — shoot day, card, session, drive — never "index" or "metadata".
- *Show, don't list:* after an offload, "these 412 clips from Tuesday aren't in a dated folder yet
  — want me to sort them?"
- *Proactive:* after a card or drive appears, a sorting offer (trigger gap, **PL-06**). *Waits:*
  every move, copy, rename and anything near deletion.
- *Trust:* shows the whole plan first, copies and verifies before removing anything, never
  deletes, reports exactly what moved, stays out of the way while they edit (fast on their Mac).

**How it should feel to them.** Like a trusted assistant editor who has already logged the
cards and knows where everything lives — invisible while they edit, there the moment they ask.

**What it sees coming, and how it says so**
- *Patterns:* card dumps every shoot evening, the same folder naming every project, backups done
  on Fridays. → "I noticed Tuesday's cards are still in Downloads. I've drafted the sort — want
  to see it?"
- *Recurring deadlines:* delivery dates, review rounds, invoice terms. → "Before you ask — the
  Brightside cut is due Thursday; the client's notes from Monday's call are ready for you."
- *People's habits:* a producer who changes delivery dates by email late at night; a client who
  sends feedback only on calls. → "Jess emailed late again — the delivery moved to Monday."
- *Seasonal moments:* wedding season, festival submission windows, year-end archive. → "Festival
  submissions close in two weeks; last year you exported the screener ten days out."
- *Quietly prepared:* the sorting plan, the backup comparison, the notes from client calls.

**Jobs mapped to what exists**

| Job | Today in code | Status / gap |
|---|---|---|
| Find footage by day | `filesystem.find` with `kind: video` and `modifiedAfter`; crawler records creation dates | File dates only; capture date/session/camera not read → **PL-07** |
| Sort a card dump into dated folders | `filesystem.move`/`copy` per file (approval each) | Plan + one approval + verified copy → **PL-07** |
| Which drive holds a project | `filesystem.tree`; index skips unmounted/network volumes | Unmounted drive must be reported as unmounted → **PL-07** |
| Backup matches source | Nothing compares two folders | Read-only compare → **PL-07** |
| Delivery dates, client feedback, call notes | Mail/calendar reads; meetings | As above; Google via **PL-09** |
| Stay fast while editing | Background work yields (`ComputeScheduler`); floor benchmark | Proven only by **PL-01/PL-02** |
| Notice card dumps left unsorted, backups not done this week | File index (creation dates), `filesystem.tree` | No pattern pass → **PL-12**; drive-mounted trigger → **PL-06** |
| Delivery-date catch-up with client notes | Digest/podcast templates; meeting notes | **PL-11** |

**Example spoken requests (for PL-05 set E)**
- "Find Tuesday's footage."
- "Where's the Henderson wedding project — which drive?"
- "Sort the new card into folders by shoot day."
- "Does the backup drive have everything from this week's shoots?"
- "When is the Brightside cut due?"
- "What did the client say about the colour on yesterday's call?"
- "How much space is left on the B drive?"
- "Copy Tuesday's footage to the backup drive, then tell me when it's checked."
- "Catch me up on the shoots this week."

---

## 6. Adjacent people in the same segment

Same traits (section 1), different nouns. Each reuses the same capabilities and gaps; listed so
copy, evals and proactive defaults can grow without new architecture. Eval sets for these pick
unused prefixes when they are written.

| Person | A day / recurring jobs | Their dream | Main fears | What maps today | Gaps (task) |
|---|---|---|---|---|---|
| **Executive / personal assistant** | Runs one or more executives' calendars, travel, inbox triage, meeting prep and follow-ups | "My boss walks into every meeting prepared, and nothing falls through" | Double-booking, wrong recipient, a missed flight change | Agenda and mail reads, meeting notes, drafts, reminders | Pre-meeting brief (AO P4-04 → **PL-06**); other people's calendars (no task); Google setup (**PL-09**) |
| **Small-business owner** (salon, trades, studio, clinic front desk) | Bookings, client messages, quotes and invoices, supplier orders, staff rota | "My admin is done by the time I close" | Missing a booking, upsetting a client, money mistakes | Calendar/mail reads, drafts, reminders, files | Booking systems and invoicing tools (no task; MCP/Composio routes exist but are unproven); purchases stay approval-only |
| **Real-estate agent / property manager** | Showings, offers and closing dates, documents per property, many parties per deal, maintenance requests | "Every deal's next step is obvious and on time" | Missing a contract deadline, sending a document to the wrong party | Calendar/mail, files per property, meeting notes, reminders | Plan-based filing (**PL-07**); deadline nudges (**PL-06**) |
| **Family caregiver** (for an aging parent) | Appointments, medications, insurance paperwork, coordinating siblings and carers | "I know everything Mum needs this week, and so do my brothers" | A missed appointment or refill; health details leaking | Calendar, reminders, files, call notes | Apple Calendar/Reminders (**PL-10**); sharing with family members (no task); health data stays on the Mac by default |
| **Event or wedding planner** | Vendors, timelines, budgets, contracts, client calls | "The day runs to plan and the client never sees the scramble" | A vendor no-show, a missed payment date | Mail, calendar, files, meeting notes | Plan-based filing (**PL-07**), deadline nudges (**PL-06**); budgets (no task) |
| **School or nonprofit coordinator** | Volunteers, rotas, parent or donor email, event logistics | "Volunteers show up and every family gets the message" | Emailing the whole list by mistake, privacy of children/donors | Mail drafts with approval, calendar, reminders | Group-send safeguards are the approval card; mailing-list tools (no task) |

**How it should feel, and what it sees coming** (predictive jobs all rest on **PL-12** for
noticing and **PL-11** for the catch-up; capabilities as in the table above)

| Person | How it should feel | What it predicts before they ask | What it quietly prepares | How it tells them |
|---|---|---|---|---|
| **Executive assistant** | A partner who has the boss's week memorised | Meetings that will run over, travel that clashes with a recurring call, the boss's Monday questions | Pre-meeting notes, a reshuffle proposal, the Monday catch-up for the boss | "Before you ask — Alex's 2 pm will clash with the flight. I've drafted two options." |
| **Small-business owner** | The calm person behind the counter who has already checked the book | Quiet days to fill, regulars due back, supplier orders that run low on a cycle | Rebooking messages (drafted), the reorder list, the end-of-day catch-up | "I noticed Mrs. Ali usually books every six weeks — it's been seven. Want me to send her a note?" |
| **Real-estate agent / property manager** | A deal coordinator who never lets a date slip | Contract milestones, inspection windows, the parties who always need chasing | The next-step list per deal, document folders, draft chase emails | "Already drafted the reminder to the buyer's lender — the finance date is Thursday." |
| **Family caregiver** | A gentle helper who carries the worry with them | Refill dates, follow-up appointments, paperwork renewals each year | The week's appointments, a draft update for the siblings | "Mum's refill is due Friday — last time the pharmacy needed two days. Want me to put it on your Wednesday list?" |
| **Event or wedding planner** | A stage manager who has run the day in their head already | Vendor confirmations due, payment dates, the week-before checklist | Confirmation drafts, the run sheet, a "what's still open" list | "Three vendors haven't confirmed for Saturday. The confirmation emails are ready for you to check." |
| **School or nonprofit coordinator** | A warm organiser everyone trusts | Volunteer gaps in next month's rota, term events, donor anniversaries | Rota gap list, draft call-out to volunteers | "Next Saturday's rota has two gaps. I've drafted a note to the usual helpers." |

---

## 7. Gaps this file found, and where they live

| Gap | Task |
|---|---|
| Agent cannot read or add to Apple Calendar or Apple Reminders lists (Google-only agenda) | **PL-10** (new, `04-PERSONA-JOBS.md`) |
| Google needs Terminal and a client secret | **PL-09** |
| Capture-date/session sorting, one-approval file plans, drive compare | **PL-07** |
| Persona-specific proactive offers; new-mail and drive-mounted triggers | **PL-06** |
| Persona eval sets | **PL-05** |
| One warm catch-up (morning, Monday, while you were out) replacing the digest and the podcast | **PL-11** (`06-CATCH-UP-AND-ANTICIPATION.md`) |
| Nothing notices patterns, recurring deadlines, people's habits or seasonal moments | **PL-12** (`06-CATCH-UP-AND-ANTICIPATION.md`) |
| Team/other people's availability, budgeting/bank data, Drive sharing state, booking/invoicing systems, sharing with family members | Recorded here; no task yet. Each needs its own approval and privacy design before it is planned |
