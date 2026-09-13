/// Two local passes, each doing the thing it is actually good at.
///
/// Kept for `--selftest-cleanup chain`. The live dictation path no longer uses this when
/// grammar is on: S1 then Apple stacked two waits and the second often timed out, so the
/// typed text was S1's punctuation with no grammar or layout. Apple already restores
/// punctuation in the same call, so production spends that budget on one pass.
///
/// Measured separately over the same 28 cases: S1-mini 0.511s warm median, Apple 0.686s.
/// The chain costs roughly the sum when both are warm, and much more when S1 is cold.
struct ChainedFormatter: TextFormatter {
    let first: any TextFormatter
    let second: any TextFormatter

    func format(_ raw: String) async -> String {
        let once = await first.format(raw)
        // Nothing survives the first stage, nothing to repair. Skipping saves a model call on
        // an utterance that was silence or filler.
        guard !once.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return once }
        return await second.format(once)
    }
}

/// Returns what it was given.
///
/// The fallback for a formatter that is not the first thing to touch the text: when the
/// grammar stage cannot run, the right answer is the punctuated sentence it was handed, not a
/// third opinion about it.
struct KeepAsIsFormatter: TextFormatter {
    func format(_ raw: String) async -> String { raw }
}
