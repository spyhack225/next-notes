/// Two local passes, each doing the thing it is actually good at.
///
/// S1-mini is a purpose-trained punctuation and capitalisation model: fast, and incapable of
/// grammar because it was never an instruction-following model. Apple's on-device model
/// repairs grammar well but is a general model being asked to do restoration. Running them in
/// that order — punctuate, then repair — gives the grammar stage a punctuated sentence to
/// work on, which is the form it handles best.
///
/// Measured separately over the same 28 cases: S1-mini 0.511s warm median, Apple 0.686s. The
/// chain costs roughly the sum, a little over a second, which is still inside the pause
/// between releasing the key and looking at the screen. The alternative that avoids the
/// second pass entirely — Qwen, which does both in one — takes 7.410s.
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
