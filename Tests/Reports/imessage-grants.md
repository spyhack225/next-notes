# IM-03 / gate G3 — the grants ledger

**What this answers:** can Full Disk Access and the Messages Automation grant be obtained
on this Mac, and does ad-hoc signing make the Automation grant unmaintainable?

**Date:** 2026-09-27 · **macOS 27.0 (26A428)** · **Sanitised:** no bundle identifier, no
team id, no certificate hash appears in this file beyond the one shape that is the finding.

**Verdict: both grants are held, and the signing threat is retired.** The Automation
grant is maintainable because the designated requirement is a real certificate leaf, not
a cdhash — so `make install` no longer invalidates it.

---

## 1. The signing question — answered, and the answer is good

The installed bundle's designated requirement is:

```text
identifier "ai.pivotstudio.nextnotes" and certificate leaf = H"96c8b8fa…"
```

**A certificate leaf, not a cdhash.** An ad-hoc signature is a hash of the binary, so the
designated requirement reads `cdhash H"…"` and changes with every compile. TCC stores that
requirement beside each grant, so Accessibility, Audio Recording and Notifications are all
invalidated together by every `make install` — and the symptom lies twice over: the toggle
still reads as on, and toggling it off and on does not repair it, because what is stale is
the stored requirement, not the switch.

`make signing-cert` has been run. The requirement is now `identifier "…" and certificate
leaf = H"…"`, which is **identical across rebuilds**. Grants survive `make install`.

**The Automation threat is retired.** The 2026-09-25 baseline recorded this as an open
risk: ad-hoc signing could make the Automation grant unmaintainable. It cannot, and the
reason is the certificate.

## 2. Full Disk Access — obtained, and the proof is a live row read

**Granted to Next Notes.** The proof is not a toggle reading — it is a live row read from
`chat.db` through the app's own process. `--imessage-self-flow --via-open` read the real
database and returned rows, which is the only evidence that matters: FDA has no query API,
so a `stat` passes where a real read fails.

**The launch mode is load-bearing, and the rule is the opposite of Automation's.**

| grant | direct launch from a shell | via LaunchServices (`--via-open`) |
|---|---|---|
| **Full Disk Access** | **denied** — TCC blames the *responsible* process, which is Terminal | **granted** — the app is the responsible process |
| **Automation (Apple Events)** | **granted** — the *client* is the app that sent the event | **silently `-1743`, no prompt at all** |

FDA is keyed to the *responsible process* — who launched the binary — so LaunchServices
must be in the chain or the grant is somebody else's. Getting this backwards costs an
hour: a direct shell launch is denied FDA while the grant is already on, and the toggle
reads as on throughout.

## 3. Automation — obtained, and the launch mode is the inverse

**Granted to Next Notes.** The proof is `IMESSAGE_SEND_PATH_OK: 200 chats readable` —
a live Apple Event that counted chats, listed accounts and sampled handles through
`osascript`.

**The launch mode is the exact inverse of FDA's, and getting it backwards costs an hour.**
`--via-open` inserts LaunchServices as the responsible process, which is precisely what
stops the Automation prompt being presented. The first three runs returned `-1743` with
no dialog; a direct launch returned `IMESSAGE_SEND_PATH_OK` on the first attempt.

**Three things that each looked like the answer and were not:**

1. **A bare `count of chats` never asks for anything.** `NSAppleScript` compiles against
   *AppleScript's* vocabulary, not the target's, so it failed with `-2753, "The variable
   chats is not defined"` — a script error, not a permission one. It never addressed
   Messages, so it never provoked a prompt. `tell application "Messages" to …` is what
   makes the event leave the process.
2. **`-1743` with no dialog is not evidence of a denial.** It is what a suppressed prompt
   looks like.
3. **`tccutil reset AppleEvents ai.pivotstudio.nextnotes` changed nothing** — the record
   it clears belongs to Next Notes; the record that mattered belonged to LaunchServices.
   A denied-looking `-1743` with no prompt is therefore *not* evidence of a denial, and
   resetting the wrong row is what a probe like this will do.

## 4. The asymmetry that makes this a product problem

**The Automation pane has no `+` button.** Full Disk Access can be granted by hand;
Automation cannot. An entry appears *only* when an application asks, so a missing entry
cannot be added by hand and the system prompt is the only route to the grant.

This is the sharpest asymmetry in the whole permission surface:

| pane | can grant by hand | can repair a stale entry |
|---|---|---|
| Full Disk Access | **yes** — the `+` button | yes — remove and re-add |
| Automation | **no** — no `+` button | no — must re-trigger the prompt |

**Consequence for the `Permissions` checklist:** the FDA row can offer a button and an
Automation row never can. The checklist's FDA row offers a button; an Automation row
would have to say "use the feature and answer the prompt," which is a different kind of
row. This is a design fact, not an omission, and it belongs in IM-17a's consent sheet.

## 5. What the probe does about it

`--imessage-send-path` is launched **directly**, and the first `-1743` is treated as a
*question* rather than a result — it prints a waiting line, sleeps, and asks again up to
four times, because the first attempt is the one that raises the prompt. An app that asks
once and exits has declined to give the person a chance, and the grant then never appears
in the list at all.

The probe is deliberately not a `--selftest-*` flag: the harness swaps the world out from
under anything that needs a real grant, and a `--selftest-*` flag that needs a grant it
cannot obtain under the harness is a flag that can only ever print `_ABSENT`.

## 6. What is left

| # | item | status |
|---|---|---|
| 1 | Full Disk Access | **held** — proved by a live row read |
| 2 | Automation | **held** — proved by `IMESSAGE_SEND_PATH_OK` |
| 3 | Signing threat | **retired** — the requirement is a certificate leaf |
| 4 | The report file | **this file** |
| 5 | The `Permissions` checklist's Automation row | **IM-17a's** — it needs the consent sheet |

**Nothing in this report is a green light for IM-09.** It establishes that both grants
are held and that the signing threat is retired. The send path itself is IM-02's report.
