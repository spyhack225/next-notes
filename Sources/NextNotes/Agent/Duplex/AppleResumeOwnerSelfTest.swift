import Foundation

/// Deprecated CLI alias. Tests simulated PCM ownership, never native playback.
@MainActor
enum AppleResumeOwnerSelfTest {
    static func run() async -> String {
        await PCMReceiptOwnerSelfTest.run(marker: "APPLE_RESUME_OWNER")
    }
}
