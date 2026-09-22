import AppKit
import Foundation

/// Keeping the promise the assistant screen makes.
///
/// Setup tells the user, in so many words, that the part which understands them is being
/// fetched and that a transfer which does not finish will be picked up again. Nothing used
/// to pick it up. `prepareNotesModel()` had exactly three callers — the setup screen itself
/// and two buttons buried in Settings — and `LocalModelStore.refresh()` only re-reads
/// whether the file is already there. So a quit halfway, a dropped connection or a full disk
/// left the user permanently without the thing they had been told was on its way, on a
/// screen they can never be shown again, because finishing setup is what stops it appearing.
///
/// This is the missing half: one attempt at launch and one each time the app comes back to
/// the front, under conditions strict enough that it can never surprise somebody.
///
/// - It never runs during a self-test. A question about a state machine must not pull
///   gigabytes onto the machine answering it.
/// - It never runs for a Mac that was never offered the screen. Somebody who finished setup
///   before this flow existed has not been promised anything, and an unannounced multi-
///   gigabyte download is worse than the button in Settings they already have.
/// - It never runs while a download is already going, while the file is already there, or on
///   a disk too full for `ModelDownloader` to accept it — the same test the screen shows.
/// - It waits `retryInterval` between attempts, so a machine that is offline all morning
///   retries on the hour rather than on every ⌘-Tab.
@MainActor
enum OnboardingModelResume {
    /// The quietest interval that still feels like "it picked itself up". Activation is a
    /// user gesture and can happen dozens of times a minute; a failed download that retried
    /// on each one would spend the day reconnecting.
    static let retryInterval: TimeInterval = 10 * 60

    private static var observer: NSObjectProtocol?
    private static var lastAttempt: Date?

    /// Called once, from `applicationDidFinishLaunching`.
    static func start() {
        guard !SelfTest.isRunning, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in OnboardingModelResume.resumeIfNeeded() }
        }
        resumeIfNeeded()
    }

    /// The free space `ModelDownloader` itself insists on, so this never starts a transfer
    /// the downloader will refuse a second later.
    static var requiredFreeBytes: Int64 {
        NotesModels.spec.expectedBytes + ModelDownloader.minimumFreeBytesAfterDownload
    }

    static func resumeIfNeeded() {
        let now = Date()
        guard shouldResume(
            wasPromised: OnboardingModel.shared.hasPromisedTheAssistant,
            isSelfTest: SelfTest.isRunning,
            // Any installed brain, not only the built-in file: someone who has since
            // installed and activated a different model from the library has already
            // kept the promise this screen made, and the stalled built-in transfer is
            // not worth resuming behind their back.
            isDownloaded: InstalledModelLibrary.shared.hasUsableModel,
            isBusy: LocalModelStore.shared.notesModelState.isBusy,
            freeBytes: ModelDownloader.availableDiskBytes(),
            requiredBytes: requiredFreeBytes,
            secondsSinceLastAttempt: lastAttempt.map { now.timeIntervalSince($0) }
        ) else { return }
        lastAttempt = now
        Log.llm.info("picking up the assistant download that setup began")
        LocalModelStore.shared.prepareNotesModel()
    }

    /// The whole decision, as a function of things a test can hand it.
    ///
    /// - Parameters:
    ///   - wasPromised: whether the user has actually been shown the screen that says this
    ///     is being set up.
    ///   - secondsSinceLastAttempt: nil when nothing has been tried yet this launch.
    static func shouldResume(
        wasPromised: Bool,
        isSelfTest: Bool,
        isDownloaded: Bool,
        isBusy: Bool,
        freeBytes: Int64,
        requiredBytes: Int64,
        secondsSinceLastAttempt: TimeInterval?
    ) -> Bool {
        guard !isSelfTest, wasPromised, !isDownloaded, !isBusy else { return false }
        if let elapsed = secondsSinceLastAttempt, elapsed < retryInterval { return false }
        return freeBytes >= requiredBytes
    }
}
