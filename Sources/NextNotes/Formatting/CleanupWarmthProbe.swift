import Foundation

/// Live measurement of which warm-up removes Apple's model's cold start (D-06).
///
/// ## Why this is a probe and not a self-test
///
/// The claim under test is physical, not logical: whether Apple's model keeps a
/// process-level warm state that a launch-time call can bank for the first real
/// dictation. Nothing deterministic can assert that, so — same shape as
/// `StructurePlanProbe` — this runs only when `--probe-cleanup-warmth <mode>` is passed
/// alongside `--selftest-cleanup-router`, prints what it measured, and asserts nothing.
///
/// Three fresh processes, one mode each:
///
/// ```bash
/// for m in none prewarm respond; do
///   Scripts/run-selftest.sh --selftest-cleanup-router --probe-cleanup-warmth $m | grep CLEANUP_WARMTH
/// done
/// ```
///
/// The mode that brings `first_call` within 0.3 s of the "later fresh session" figure
/// (1.42–1.58 s, the `CleanupSessionWarmer` table) is the one `AppleModelWarmth.mode`
/// ships with.
enum CleanupWarmthProbe {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--probe-cleanup-warmth")
    }

    /// `<none|prewarm|respond>`; anything else reads as `none` and is reported as such.
    static var mode: String {
        let requested = SelfTest.value(after: "--probe-cleanup-warmth")
        return (requested == "prewarm" || requested == "respond") ? requested! : "none"
    }

    static func run() async {
        emit("")
        emit("=== cleanup warmth probe (live Apple Intelligence) ===")
        guard FoundationModelFormatter.isAvailable else {
            emit("  unavailable: \(FoundationModelFormatter.unavailableReason ?? "unknown")")
            emit("CLEANUP_WARMTH mode=\(mode) first_call=unavailable")
            return
        }
        // The fixed fixture the task names. Short enough that the model's wake-up, not
        // its work, dominates the number.
        let fixture = "okay so um I think we should ship it on friday"

        switch mode {
        case "prewarm":
            await AppleModelWarmth.setMode(.prewarm)
            await AppleModelWarmth.warmProcess()
            // A staged session is worth nothing until the framework has had a moment to
            // act on `prewarm()`; at key-down that gap is filled with seconds of speech.
            try? await Task.sleep(for: .seconds(1))
        case "respond":
            await AppleModelWarmth.setMode(.respond)
            await AppleModelWarmth.warmProcess()
        default:
            await CleanupSessionWarmer.shared.clear()
        }

        // One real cleanup, timed. In `prewarm` mode this takes the staged session — the
        // instructions match by construction; in `respond` and `none` it builds a fresh
        // session. That difference is exactly what is being measured.
        let began = Date()
        _ = (try? await FoundationModelFormatter.clean(
            fixture,
            preferences: AppleModelWarmth.warmPreferences,
            fixesGrammar: AppleModelWarmth.warmFixesGrammar,
            target: .plain(bundleID: "", displayName: "the focused app"),
            context: .empty
        )) ?? ""
        let seconds = Date().timeIntervalSince(began)
        emit(String(format: "CLEANUP_WARMTH mode=%@ first_call=%.2f", mode, seconds))
    }

    private static func emit(_ line: String) {
        CleanupSelfTestLog.emit(line)
    }
}

/// Live measurement of how many sentence groups Apple's model will actually take at once
/// (D-08) — the number `ChunkedFormatter.width` is, and the number the wave-aware ceilings
/// are priced against.
///
/// ## Why this is a probe and not a self-test
///
/// Same shape as `CleanupWarmthProbe`: the claim is physical, not logical. It runs the same
/// two ~90-word groups through the real `ChunkedFormatter` and the real
/// `FoundationModelFormatter` at width 1 and at width 2, in a process warmed first, and
/// prints what each took. It asserts nothing and its numbers do not gate anything:
///
/// ```bash
/// Scripts/run-selftest.sh --selftest-cleanup-router --probe-chunk-width | grep CHUNK_WIDTH
/// ```
///
/// The rule, and the constant it sets (`CleanupRouter.appleChunkWidth`): keep width 2 for
/// Apple when `w2_wall ≤ 0.85 × w1_wall`, otherwise width 1. Fifteen percent is the margin
/// a second request has to beat to be worth asking for, and the run's answer is quoted in
/// the comment above that constant. Both widths are measured twice and the faster run of
/// each is reported, because the first round pays for whatever the warm-up did not cover
/// and the second one is what a user's second dictation looks like.
enum ChunkWidthProbe {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--probe-chunk-width")
    }

    /// Two groups of the shape a long dictation actually splits into: spoken, slightly messy,
    /// and long enough that the model has real work to do rather than a punctuation pass.
    private static let groups = [
        """
        Okay so um I think we should ship the installer on Friday afternoon and the release \
        note goes out the same day, and then uh the beta group gets it on Monday morning \
        before the launch, and support is going to be watching the forum all week to see \
        what breaks, and there is a dashboard for that so we can see it without digging \
        through logs all morning like we did last time, and if the numbers are going down \
        then we know the fix landed.
        """,
        """
        The other thing is the onboarding copy, it still reads as though we charge for the \
        trial, and we have not charged for the trial since March, so I want that changed \
        before anybody else signs up and finds out, and legal says the wording in the \
        terms has to match whatever the screen says, so uh somebody should check both of \
        those together rather than one and then the other, and the help article is a third \
        place that says the old thing.
        """,
    ]

    static func run() async {
        emit("")
        emit("=== chunk width probe (live Apple Intelligence) ===")
        guard FoundationModelFormatter.isAvailable else {
            emit("  unavailable: \(FoundationModelFormatter.unavailableReason ?? "unknown")")
            emit("CHUNK_WIDTH w1_wall=unavailable w2_wall=unavailable")
            return
        }
        let counts = groups.map { SentenceChunker.wordCount($0) }
        emit("CHUNK_WIDTH_NOTE: two groups of \(counts[0]) and \(counts[1]) words, best of 2 rounds each")

        // Warm first, and through the same code a hold uses. Both measurements then start
        // from the same state, which is the whole point: an un-warmed first call measures
        // the wake-up twice and answers nothing about width.
        _ = try? await FoundationModelFormatter.clean(
            "okay so um I think we should ship it on friday",
            preferences: AppleModelWarmth.warmPreferences,
            fixesGrammar: AppleModelWarmth.warmFixesGrammar
        )

        let w1 = await bestWall(width: 1)
        let w2 = await bestWall(width: 2)
        emit(String(format: "CHUNK_WIDTH w1_wall=%.2f w2_wall=%.2f", w1, w2))
        let bar = w1 * 0.85
        let width = w2 <= bar ? 2 : 1
        emit(String(
            format: "CHUNK_WIDTH_RULE: bar=%.2f w2 %@, so Apple's width is %d",
            bar, w2 <= bar ? "is inside" : "is over", width
        ))
    }

    /// The faster of two rounds of one width, through the real chunker and the real
    /// formatter, with only the width differing between the two measurements.
    private static func bestWall(width: Int) async -> Double {
        var best = Double.infinity
        for _ in 0..<2 {
            let chunked = ChunkedFormatter(
                inner: FoundationModelFormatter(
                    fixesGrammar: true,
                    target: .plain(bundleID: "", displayName: "the focused app"),
                    context: .empty,
                    fallback: KeepAsIsFormatter()
                ),
                maxWords: 120,
                // Long enough that no wave is refused, so the number is the model's and not
                // the budget check's.
                budget: .seconds(120),
                perCallTimeout: { _ in .seconds(30) },
                width: width
            )
            let began = ContinuousClock.now
            _ = await chunked.format(groups.joined(separator: " "))
            best = min(best, elapsed(began))
        }
        return best
    }

    private static func elapsed(_ began: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - began
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func emit(_ line: String) {
        CleanupSelfTestLog.emit(line)
    }
}
