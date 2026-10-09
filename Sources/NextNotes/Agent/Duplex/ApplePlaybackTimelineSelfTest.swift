import Foundation

/// Deprecated name for the retained native prepared-PCM timeline producer.
/// Authored muted PCM; not Apple synthesis or a Pocket/Kokoro resume capability.
@MainActor
enum ApplePlaybackTimelineSelfTest {
    static func run() async -> String {
        let failures = await NativePCMReceiptSelfTest.run()
        for failure in failures { SelfTest.diagnostic("APPLE_PLAYBACK_TIMELINE_WRONG: " + failure) }
        return failures.isEmpty && !SelfTest.failed ? "APPLE_PLAYBACK_TIMELINE_OK: native authored PCM callback/cursor/owner checks; audibility unverified"
            : "APPLE_PLAYBACK_TIMELINE_FAILED: \(failures.count) assertions"
    }
}
