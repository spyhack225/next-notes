import Foundation

/// What the Sensitivity slider actually does.
///
/// It used to do almost nothing. The only knob it reached was sherpa's global keyword
/// threshold, mapped `0.45 - sensitivity * 0.3`, and on this model that number is flat
/// across most of its range: sweeping a single “Hey Will” keyword over thresholds
/// 0.25, 0.15 and 0.05 gave the same 49 hits out of 90 accented clips, every time. The
/// user was already at maximum sensitivity and it had nothing left to give.
///
/// So the slider now moves the things that were measured to matter:
///
/// | sensitivity | threshold | variants | beam | measured |
/// |---|---|---|---|---|
/// | 0.0 (conservative) | 0.45 | 0 | 4 | 44/90 recall, 0/32 false |
/// | 0.6 (default) | 0.15 | 2 | 16 | 59/90 recall, 2/32 false |
/// | 1.0 (sensitive) | 0.15 | 4 | 24 | 67/90 recall, 2/32 false |
///
/// Measured over a grid of beam × variants × variant threshold × trailing blanks ×
/// threshold, scored on 90 synthesised clips of “Hey Will” (15 voices × 3 speech
/// rates, half of them with a request after the phrase) and 32 deliberately
/// adversarial negatives (“hey Bill can you check the numbers”, “I will send you the
/// file”, “hey we need to talk about the budget”).
///
/// The committed re-run of that grid is `Tests/Fixtures/wake/` (recipe in its README,
/// runner `--selftest-wake-live` in `WakeWordLiveSelfTest.swift`): 24 hits across 8
/// voices × 3 rates plus optional local microphone captures for real rooms, and 32
/// negatives grown from the three seeds above. The table below is the claim; the
/// fixture grid is the check.
///
/// The shipped behaviour — beam 4, no variants, threshold 0.15 — hit **52/90** with
/// no false accepts. Every setting at or above the default here beats it on recall,
/// and the two false accepts it costs are the same adversarial sentence in two voices.
///
/// The beam matters more than anything else once there is more than one pronunciation
/// on file: with sherpa's stock width of 4 the variants evict each other from the
/// lattice and four of them bought two extra hits. At 24 the same four are worth
/// fifteen. Past four variants recall stops improving and starts falling back (6
/// variants scored 64/90 where 4 scored 67), which is why the slider stops there.
struct WakeWordTuning: Sendable, Equatable {
    /// Global keyword threshold handed to sherpa.
    var threshold: Float
    /// Threshold written onto each accent variant line. Variants are looser matches by
    /// construction, so they are held to a stricter bar than the canonical spelling.
    var variantThreshold: Float
    /// How many accent variants to write.
    var variantDepth: Int
    /// Decoder beam width.
    var maxActivePaths: Int32
    /// Blank frames required after the last keyword token before it fires.
    ///
    /// Not on the slider: the grid says two is simply better than sherpa's default of
    /// one at every beam width worth using. At beam 24 with variants it kept the same
    /// 67/90 recall and cut false accepts from 7 to 3.
    var numTrailingBlanks: Int32

    static func forSensitivity(_ sensitivity: Double) -> WakeWordTuning {
        let s = min(1, max(0, sensitivity))
        return WakeWordTuning(
            // Saturating on purpose. Recall is flat below 0.15 (67/90 at 0.15, 0.10
            // and 0.05 alike) while false accepts keep creeping up, so the top half of
            // the slider stops lowering it and spends its range on pronunciations and
            // beam instead — the two knobs that were still buying something.
            threshold: Float(max(0.15, 0.45 - 0.60 * s)),
            variantThreshold: Float(max(0.30, 0.45 - 0.15 * s)),
            variantDepth: Int((s * 4).rounded()),
            maxActivePaths: Int32(4 + Int((s * 20).rounded())),
            numTrailingBlanks: 2
        )
    }

    /// The sensitivity the app ships with when nothing has been chosen.
    static let `default` = WakeWordTuning.forSensitivity(0.6)
}
