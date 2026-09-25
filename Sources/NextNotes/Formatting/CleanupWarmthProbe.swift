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