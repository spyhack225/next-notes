# Audio wake confirmation

The actual AudioCaptureHub callback now acknowledges first, checks the bounded hit window with an already-resident ASR engine, and retracts a rejected wake before turn dispatch. Captured session identity refuses stale results; quit retains and joins actual entered confirmation work. Microphone and recognition continue while confirmation is pending. No cold model load or download occurs on a wake hit.

Original callback fixture: 63 failures. Two were an invalid newly authored accent-word-boundary expectation; the retained trace confirms the existing scorer returns `need` for `hey we need`. The corrected callback case verifies preserving that existing remainder; its stronger semantic boundary stays open. The other original confirmation/dispatch/ownership assertions are unchanged and pass. Actual callback, normal wake model, voice-turns, routing and store isolation (21 files/32 defaults) pass.

Voice-work-lifecycle remains failed: all 44 installed-baseline cancellation/receipt failures recur; fixed also observes status-2 at 119.1 ms versus baseline 14.9 ms (50 ms limit). The unchanged deterministic status path does not call the new confirmation producer; timing cause is unproven and no speed gate is promoted. Recorded once, no repeated micro-pairs.

The corpus scorer uses the same first-hit window and confirmation; missing resident ASR is unavailable, never a pass. Acoustic corpus/room accuracy, physical first display, full native quit, and the accent boundary remain open. UI-owner files were excluded. Raw logs/patches: `~/Library/Caches/NextNotesBuild/integration/wake/`.
