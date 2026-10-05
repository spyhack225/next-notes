# Canceled voice request — 2026-10-05

`FrontendResponder.unsharedStream` treated cancellation of its existing prior-generation wait as a timeout, discarded the retained owner and started a fresh generation for a canceled request. It now checks cancellation after the same wait and returns a canceled stream before detaching or creating inference.

Original/fixed `--selftest-voice-delivery`: **RED5 → GREEN**, identical held entered owner, canceled waiting call and next live request. The prior owner remains retained; canceled work starts no inference; the next live call receives its exact reply and both actual retained Task owners finish. Voice routing, concurrent voice, duplex and store isolation pass. The external generator is scripted: this is not native-kernel, physical audio or speed evidence.

Evidence: `~/Library/Caches/NextNotesBuild/integration/voice-cancelled-drain/`. The latest pinned MiniCPM quick before this independent voice slice is **9/9/9** on bffc8d6. Earlier voice preparation medians remain L1 .671s / L2 2.448s / L3 2.649s; no latency improvement is attributed to this cancellation repair. 200ms, full/owner and physical acceptance remain open. No extra wait, queue, model pass or persisted choice is added.
