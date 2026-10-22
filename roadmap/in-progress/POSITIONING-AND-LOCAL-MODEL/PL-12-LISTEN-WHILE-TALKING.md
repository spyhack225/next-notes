# PL-12 — Listen while the person talks (owner decision, 2026-10-05)

## The rule

Full duplex means the agent works **while the person is still talking**, the way dictation already
transcribes and tidies during the hold. It does not wait for the end of the sentence to start.
**Processing is not answering:** the agent processes continuously, but it **answers only when the
person stops**. In between it may keep the conversation alive with short listening sounds
("mm", "okay", "I hear you"). The person always knows they are being heard.

## What is measured (supersedes the "from end of turn" definition earlier on 2026-10-05)

All on the 16 GB M3/Air with ASR + voice running and the model warm. Median is the gate; p95 is reported.

| # | Measure | From | To | Target |
|---|---|---|---|---|
| L1 | **Heard and processing** | speech onset (first voiced audio frame) | the agent's processing has started on that speech (first partial fed to the model/prefill) | **< 200 ms** |
| L2 | **Ready to answer** | committed end of turn | first answer token | **< 200 ms** (the work is already done) |
| L3 | First audio | committed end of turn | first audible answer sample | reported, no gate yet |
| L4 | Listening sounds | — | — | never over the person's words; never read as the agent's answer or a barge-in; at most one per natural pause |

## What exists today (checked 2026-10-05)

- `VoiceConversationCoordinator.prepareResponseIfUseful` drafts a whole answer from a stable partial. It
  waits for **≥ 4 words**, then sleeps a fixed **220 ms**, and `FrontendResponder` reuses the draft only
  on an **exact** final-request match. It starts late and is all-or-nothing.
- The live voice frontend answers on **Apple Foundation Models**, which offers no KV-cache control. It can
  re-draft but cannot build up a prompt word by word. The llama.cpp runtime can: `PrefixReuse.keepCount`
  plus `llama_memory_seq_rm` trim to a shared prefix.
- `VoiceTurnPolicy.isBackchannel` recognises the **person's** backchannels. Nothing produces the
  **agent's** listening sounds.

## Direction (Codex implements; smallest diff in the existing seams)

1. **Incremental prefill.** As partials arrive, append the stable words to the resident model's context
   (prefix cache). On an ASR revision, trim back to the shared prefix rather than discarding everything.
   Drop the 4-word / 220 ms wait.
2. **Early understanding.** Classify intent and start **read-only** work (calendar, mail search, meeting
   lookup) on stable partials. This reuses the rule "background planning and reads continue during
   conversation". Writes still wait for the committed turn plus approval. A revised partial cancels or
   replans stale reads.
3. **Answer only at end of turn.** The EOU commit releases the already-prepared answer (L2).
4. **Agent listening sounds.** A short sound at a natural pause in a long turn. It goes through the one
   audio-start channel (`OutputScheduler`), never creates a second audio path, is excluded from
   barge-in/echo, carries no content and is never stored as a reply. It is off in dictation.
5. **The answering model.** Measure L1/L2 with the Apple frontend as is, then with MiniCPM (resident,
   thinking off) as the live voice answerer. Report both; the owner picks.

## Proof

- One red→green self-test per producer.
- `--selftest-voice-latency` real baseline extended with L1/L2/L3 columns. Report the current numbers
  first.
- Duplex, voice-turn-routing and store-isolation stay green.
- No regression to the dictation tail.
