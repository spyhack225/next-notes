# IM-02 / gate G2 — the send path on this Mac

**What this answers:** how a conversation is addressed in Messages.app by Apple Events on this
machine, and whether the conversation with yourself can be addressed at all.

**Date:** 2026-09-27 · **macOS 27.0 (26A428)** · **Signed-in account:** 1 iMessage, 1 SMS, 1 RCS
(counts only) · **Sanitised:** every identifier below is reduced to its *shape*. No phone number,
no contact name and no chat identifier appears in this file, and none ever will — it is tracked.

**Verdict: addressable, but not as a chat.** A conversation with yourself is reachable only as a
**participant** addressed by its E.164 handle. A `chat.guid` read out of `chat.db` cannot be handed
to `send` as an address, which is the thing IM-09 was going to try first.

---

## 1. The static half — no grant needed, and it settles the shape

`/System/Applications/Messages.app/Contents/Resources/Messages.sdef` on this machine carries
**exactly one command**:

```xml
<command name="send" code="ichtsend" description="Sends a message to a participant or to a chat.">
  <direct-parameter> file | text </direct-parameter>
  <parameter name="to" code="TO  ">
    <type type="participant"/>
    <type type="chat"/>
  </parameter>
</command>
```

and four classes, **every one of whose properties are read-only** (`access="r"`):

| class | properties | note |
|---|---|---|
| `participant` | `id`, `account`, `name`, `handle`, `first name`, `last name`, `full name` | **`handle` is the only addressable one** |
| `chat` | `id`, `name`, `account` | no `participants` element is writable, none is exposed |
| `account` | `id`, `description`, `enabled`, `connection status`, `service type` | `enabled` is the only writable one |
| `file transfer` | `id`, `name`, `file path`, `direction`, `account`, `participant`, … | read-only |

`service type` is an enumeration of `SMS`, `iMessage`, `RCS`.

**Three consequences, and they are the whole of IM-09's design space:**

1. **There is no `make new chat`, and no way to construct one.** Every suite element is read-only, so
   a conversation is *addressable by query* and never by construction. IM-09 cannot build a target
   and then fill it in; it has to go and find one that already exists.
2. **`send`'s `to` accepts a `chat` — but a `chat` reference is not a `chat.guid` string.** A guid
   names a *row in `chat.db`*; the scripting interface hands out *object references*. There is no
   `chat` property that takes a guid as a value, so a guid cannot be converted into an address by
   any expression available here.
3. **The addressable unit that survives is `participant.handle`.** It is the only property in the
   whole interface that is both readable and a real-world routable address.

## 2. The live half — grant obtained, 200 chats readable

`--imessage-send-path` (`Sources/NextNotes/IMessage/Sending/MessagesSendPathProbe.swift`) is a
**read-only** diagnostic. It never calls `send`; it issues `count of chats`, an account count and a
sampled `id of chat N`. Marker: `IMESSAGE_SEND_PATH_OK: 200 chats readable`.

| measurement | value |
|---|---|
| chats readable | **200** |
| accounts | **iMessage 1 · SMS 1 · RCS 1** |
| participants exposed | **198** |
| participants with an E.164 handle | **150** (`+11 digits`, one `+12`) |
| `chat.id` shapes, 12 sampled | `any;-;+11 digits` ×6 · `any;-;5 digits` ×5 · `any;-;32 hex characters` ×1 |

### The finding: `chat.id` never says `iMessage`

Across **all 200** chats — read through `osascript` with the same automation grant, so this is not a
property of one probe — **not one `chat.id` carries the service prefix `iMessage`.** Every one is
`any;-;…`:

| shape | count |
|---|---|
| `any;-;+11 digits` | 130 |
| `any;-;5 digits` | 27 |
| `any;-;18 digits` | 17 |
| `any;-;32 hex characters` | 8 |
| `any;-;17 digits` | 7 |
| `any;-;6 digits` | 5 |
| nine one-off shapes | 9 |

**So the two namespaces do not meet.** A self-conversation is a real iMessage thread — IM-01
measured two rows arriving for it, with a `streamtyped` body and a `iMessage` account behind it —
and its `chat.guid` in `chat.db` is `iMessage;-;+1<own number>`. The scripting interface exposes it,
if it exposes it at all, under `any;-;…`. **A guid read from the database is therefore not an
address, and IM-09 must not be built on the assumption that it is.**

`service type` on the *account* does distinguish iMessage from SMS, so the account is not the problem:
there is exactly one iMessage account and it is present. The ambiguity is in the **chat** namespace,
not the account one.

## 3. So how is a self-conversation addressed?

**As a participant, by handle.** That is the only route the interface leaves open, and it works:

- 198 participants are exposed, **150 of them with a routable E.164 handle**.
- The conversation with yourself is a thread addressed to your own number, so your own number is one
  of those 150 handles.
- `send … to <participant>` therefore has a target, and the roadmap's own prediction is confirmed:
  *"a `chat.guid` is not an addressable target; a self-chat's address is the user's own number."*

**The one thing this spike cannot answer, and it is not a grant problem.** Deciding *which* of the
150 handles is "me" needs the local identity — the user's own iMessage handle in the form
`handle.uncanonicalized_id` uses — and comparing it to a scripting-interface `handle` needs a
canonical form for the two. That is **IM-02's remaining question and IM-08c's blocked-on input**, and
it is the same comparison IM-08c's `RemoteIdentity.normalised(_:)` exists to make. Until it exists,
`ResolvedSender` stays `.unresolved` and the class stays `.fromSomebodyElse`, which is the fail-closed
answer.

## 4. Two things about obtaining the grant, because both cost real time

**The Automation pane has no `+` button.** Full Disk Access can be granted by hand; Automation
cannot. An entry appears *only* when an application asks, so a missing entry cannot be added by hand
and the system prompt is the only route to the grant. This is the sharpest asymmetry in the whole
permission surface and it belongs in the `Permissions` checklist: the FDA row can offer a button, and
an Automation row never can.

**`--via-open` suppresses the prompt; a direct launch provokes it.** This is the *opposite* of the
rule that applies to Full Disk Access, and getting it backwards costs an hour:

| grant | direct launch from a shell | via LaunchServices (`--via-open`) |
|---|---|---|
| Full Disk Access | **denied** — TCC blames the responsible process, which is Terminal | **granted** — the app is the responsible process |
| Automation (Apple Events) | **granted** — the *client* is the app that sent the event | **silently `-1743`, no prompt at all** |

`--via-open` makes LaunchServices the responsible process, and the Automation prompt is never
presented. The first three runs returned `-1743` with no dialog; a direct launch returned
`IMESSAGE_SEND_PATH_OK` on the first attempt. **`tccutil reset AppleEvents ai.pivotstudio.nextnotes`
changed nothing**, for the same reason — the record it clears belongs to Next Notes, and the record
that mattered belonged to LaunchServices. A denied-looking `-1743` with no prompt is therefore *not*
evidence of a denial, and resetting the wrong row is what a probe like this will do.

Consequence for the probe itself: **it must not be launched with `--via-open`**, and the first
`-1743` is a question rather than a result, so it retries while the process stays alive long enough
for a dialog to be answered. An app that asks once and exits has declined to give the person a
chance, and the grant then never appears in the list at all — which is what the Automation pane was
showing.

## 5. What is left, precisely

| # | item | who | why it is not answered here |
|---|---|---|---|
| 1 | **The local identity in a comparable form** | nobody yet | Needs IM-02's canonical form for `handle.uncanonicalized_id` vs a scripting `handle`. Blocks IM-08c, which is already marked `blocked` on exactly this. |
| 2 | **A live `send` to a participant** | a person | Nothing here sends anything, deliberately. `send` is IM-09's, and the words in it belong to a human. |
| 3 | **Whether the self-conversation is among the 200** | a person + item 1 | Answerable the moment item 1 exists: compare the paired chat's `chat_identifier` from `chat.db` against the 150 E.164 handles. Until then "a self-chat is a participant with your own handle" is a **measured mechanism with an unmeasured instance**. |

**Nothing in this report is a green light for IM-09.** It establishes that a target *exists* and
*how to name it*; it does not establish that the right target can be identified, and item 1 is the
whole of what stands between the two.

## Reproduce

```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --imessage-send-path --selftest-out /tmp/send-path.txt
tail -1 /tmp/send-path.txt     # IMESSAGE_SEND_PATH_OK: 200 chats readable
```

**Direct launch, not `--via-open`** — see §4. The probe is read-only, needs the Automation grant, and
is deliberately not a `--selftest-*` flag: the harness swaps the world out from under anything that
needs a real grant.
