import AppKit
import CoreGraphics
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// MARK: - LLMImage

/// One screenshot, held in memory only.
///
/// Defined here — not in `Formatting/LLM/LLMProvider.swift`, which is owned by another
/// workstream — so the vision providers gain images without a protocol change: each
/// provider file (`OpenRouterLLMProvider.swift`, `OpenAICompatibleLLMProvider.swift`) has
/// its own extension point that accepts this value.
///
/// Privacy contract: an `LLMImage` is never written to disk, never logged, and never
/// uploaded unless `VisionScope.maySend` *and* the per-run `VisionConsentGate` both say
/// so. With the default settings both are off, so a screenshot backs the live working
/// view (P1-1) and goes no further.
struct LLMImage: Sendable {
    /// The capture, downscaled to ≤1280px on the long edge.
    var data: Data
    /// `"image/jpeg"` or `"image/png"`.
    var mimeType: String
    /// Small preview of exactly what would be sent, shown on the per-run consent sheet.
    var thumbnail: Data
    var pixelWidth: Int
    var pixelHeight: Int

    /// `image_url` content part for an OpenAI-compatible chat request, or nil when the
    /// image must not leave the Mac. The fail-closed shape: callers build vision
    /// requests through this, never by hand-rolling a data URL.
    func contentPart(consent: Bool) -> [String: Any]? {
        guard VisionScope.maySend(self, consent: consent) else { return nil }
        return [
            "type": "image_url",
            "image_url": ["url": "data:\(mimeType);base64,\(data.base64EncodedString())"],
        ]
    }
}

// MARK: - VisionScope

/// Which model may be shown a screenshot: set by whoever resolved the planner.
///
/// Mirrors `KnowledgeGraphScope` on purpose. A screenshot of the user's screen is at
/// least as sensitive as the distilled meeting graph, so it gets the same shape: local
/// readers (including the loopback `localServer`, where nothing leaves the machine) may
/// see it; a cloud reader — or an unknown one — only with explicit consent. That consent
/// is twofold: the persistent `visionCloudConsent` switch (off by default) *and* the
/// per-run `VisionConsentGate` sheet showing the thumbnail.
enum VisionScope {
    @TaskLocal static var reader: LLMProviderID?

    static func maySend(_ image: LLMImage?, consent: Bool) -> Bool {
        guard image != nil else { return false }
        return switch reader {
        // `localServer` is a loopback-only server on this same Mac, so it is on-device
        // in the sense that matters here: nothing leaves the machine.
        case .appLLM, .appleFoundation, .localServer: true
        case .openRouter, nil: consent
        }
    }
}

// MARK: - VisionConsentGate

/// What the surface agent shows before a screenshot leaves the Mac.
struct VisionConsentRequest: Sendable {
    /// Exact bytes that would be sent.
    var thumbnail: Data
    var reason: String?
}

/// Per-run vision consent. The hook is wired by the surface agent (P1-1) to a sheet
/// showing `request.thumbnail` next to the step list's "sent 1 screenshot" line.
///
/// Nil by default, and nil denies: without a surface to show the thumbnail on, no
/// screenshot is uploaded. Screenshots still work locally for the live view.
enum VisionConsentGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _hook: (@Sendable (VisionConsentRequest) async -> Bool)?

    /// Wired by the surface agent to a sheet showing the thumbnail. Never set by the
    /// model path.
    static var hook: (@Sendable (VisionConsentRequest) async -> Bool)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _hook
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _hook = newValue
        }
    }

    static func requestApproval(thumbnail: Data, reason: String?) async -> Bool {
        guard let hook = hook else { return false }
        return await hook(VisionConsentRequest(thumbnail: thumbnail, reason: reason))
    }
}

// MARK: - VisionStepLine

/// The step-list line the working surface renders when a screenshot is uploaded.
/// A string API on purpose: the island and Agent pane are owned by the surface agent,
/// which owns the rendering; this keeps the wording identical everywhere.
enum VisionStepLine {
    static func sentScreenshot(_ count: Int) -> String {
        count == 1 ? "sent 1 screenshot" : "sent \(count) screenshots"
    }
}

// MARK: - ScreenshotPolicy

/// Screenshots are a last resort, not the default (roadmap P1-2): take one only after
/// an accessibility snapshot came back a stub tree, or when the model explicitly asked
/// for pixels with a reason.
///
/// A pure function of strings so the self-test runs anywhere, without a grant or a
/// window. The stub check mirrors `AccessibilitySnapshot.isStub` without depending on
/// its `@MainActor` isolation.
enum ScreenshotPolicy {
    static func isNeeded(snapshotSummary: String, reason: String?) -> Bool {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return true }
        return snapshotSummary.contains("stub tree, 0 names")
            || snapshotSummary.contains("no focused window")
    }
}

// MARK: - ScreenshotStore

/// Where an executor parks a capture so the vision call can pick it up without the
/// image crossing `AgentToolResult` (whose shape is owned elsewhere).
///
/// Memory only, last-write-wins per key, consumed on read: a screenshot that nobody
/// picks up for a vision call evaporates instead of accumulating.
enum ScreenshotStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String: LLMImage] = [:]

    static func store(_ image: LLMImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        images[key] = image
    }

    /// Removes and returns the parked image, if any.
    static func take(for key: String) -> LLMImage? {
        lock.lock()
        defer {
            images.removeValue(forKey: key)
            lock.unlock()
        }
        return images[key]
    }

    static func peek(for key: String) -> LLMImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }
}

// MARK: - ScreenCapture

/// Thread-safe hand-off for the blocking sync capture path.
private final class CaptureOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<LLMImage, Error>?

    func set(_ value: Result<LLMImage, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> Result<LLMImage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Focused-window screenshots for the moments Accessibility cannot describe: a canvas,
/// a seat-picker, a custom control.
///
/// One capture implementation, one contract (focused window only, ~1x scale, ≤1280px on
/// the long edge, JPEG bytes plus a thumbnail, never disk):
///
/// - `captureFocusedWindow()` — async, for async executors (browser CDP fallback) and
///   the live view.
/// - `captureFocusedWindowSync()` — the same ScreenCaptureKit capture awaited on a
///   detached task, for the synchronous computer-tool runtime
///   (`ComputerToolExecutor.run` is sync, and its contract is owned elsewhere).
///   `CGWindowListCreateImage` is unavailable from macOS 26, so there is one capture
///   path now, not two.
enum ScreenCapture {
    /// Long edge of the captured image. A seat grid stays readable; a token bill stays
    /// small.
    static let maxEdge = 1_280
    static let thumbnailEdge = 256

    // MARK: Async (ScreenCaptureKit)

    /// Capture the focused window of the frontmost application. Throws when there is
    /// no frontmost app, it owns no on-screen window, or capture is unavailable.
    @MainActor
    static func captureFocusedWindow() async throws -> LLMImage {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AgentError.backendUnavailable("There is no frontmost application to screenshot.")
        }
        return try await captureWindow(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    // MARK: Sync (for the sync computer-tool runtime)

    /// Synchronous focused-window capture. Blocks on the ScreenCaptureKit path for at
    /// most `timeout` seconds; the capture itself runs on a detached task, which does
    /// not need the main thread, so the caller only waits.
    @MainActor
    static func captureFocusedWindowSync(timeout: TimeInterval = 5) throws -> LLMImage {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AgentError.backendUnavailable("There is no frontmost application to screenshot.")
        }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        let outcome = CaptureOutcome()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                outcome.set(.success(try await captureWindow(pid: pid, bundleID: bundleID)))
            } catch {
                outcome.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success,
              let result = outcome.get()
        else {
            throw AgentError.backendUnavailable("The screenshot timed out.")
        }
        return try result.get()
    }

    /// The one capture implementation: the focused window of the given process, or any
    /// on-screen window of its bundle when the pid is gone. Usable from any executor.
    static func captureWindow(pid: pid_t, bundleID: String?) async throws -> LLMImage {
#if canImport(ScreenCaptureKit)
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: {
            ($0.owningApplication?.processID == pid
                || (bundleID != nil && $0.owningApplication?.bundleIdentifier == bundleID))
                && $0.isOnScreen
        }) else {
            throw AgentError.backendUnavailable(
                "The frontmost application has no on-screen window to screenshot."
            )
        }
        var configuration = SCStreamConfiguration()
        let frame = window.frame
        let (width, height) = ScaledSize.fit(
            width: Int(frame.width), height: Int(frame.height), maxEdge: maxEdge
        )
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
        return try encode(cgImage: image)
#else
        throw AgentError.backendUnavailable("Screen capture is not available on this system.")
#endif
    }

    // MARK: Encoding

    static func encode(cgImage: CGImage) throws -> LLMImage {
        let (width, height) = ScaledSize.fit(
            width: cgImage.width, height: cgImage.height, maxEdge: maxEdge
        )
        let fullBitmap = try bitmap(cgImage: cgImage, width: width, height: height)
        guard let jpeg = fullBitmap.representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        ) else {
            throw AgentError.backendUnavailable("The screenshot could not be encoded.")
        }
        let (thumbWidth, thumbHeight) = ScaledSize.fit(
            width: width, height: height, maxEdge: thumbnailEdge
        )
        let thumbBitmap = try bitmap(cgImage: cgImage, width: thumbWidth, height: thumbHeight)
        guard let thumb = thumbBitmap.representation(
            using: .jpeg, properties: [.compressionFactor: 0.7]
        ) else {
            throw AgentError.backendUnavailable("The screenshot thumbnail could not be encoded.")
        }
        return LLMImage(
            data: jpeg, mimeType: "image/jpeg",
            thumbnail: thumb, pixelWidth: width, pixelHeight: height
        )
    }

    private static func bitmap(cgImage: CGImage, width: Int, height: Int) throws -> NSBitmapImageRep {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw AgentError.backendUnavailable("The screenshot could not be scaled.")
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw AgentError.backendUnavailable("The screenshot could not be scaled.")
        }
        return NSBitmapImageRep(cgImage: scaled)
    }

    /// Pure downscale math, so the self-test pins the pixel budget without a window.
    enum ScaledSize {
        static func fit(width: Int, height: Int, maxEdge: Int) -> (Int, Int) {
            let longEdge = max(width, height)
            guard longEdge > maxEdge, longEdge > 0 else { return (width, height) }
            let scale = Double(maxEdge) / Double(longEdge)
            return (
                max(1, Int((Double(width) * scale).rounded(.down))),
                max(1, Int((Double(height) * scale).rounded(.down)))
            )
        }
    }
}

// MARK: - VerifyRetry (P1-4)

/// One re-inspect and one retry with the refreshed state, then a sentence in words.
///
/// The executor calls this only when the first attempt came back unverified
/// (`verification == nil`) **and** `risk <= .modify`. Sends and above are never
/// retried: running a send twice is exactly the failure this exists to prevent.
///
/// Both attempts are returned so the caller logs each as a step in the working
/// surface's list (P1-1): the retry must be visible, not silent.
enum VerifyRetry {
    struct Attempt: Sendable {
        var summary: String
        var verification: String?
    }

    /// Run `act` once; on an unverified result with `risk <= .modify`, re-inspect via
    /// `reinspect` and run `act` exactly once more. Returns every attempt plus the
    /// user-facing sentence for the mismatch case.
    static func run(
        risk: AgentRisk,
        title: String,
        expected: String,
        observed: () -> String,
        reinspect: () -> Void,
        act: () throws -> Attempt
    ) throws -> (attempts: [Attempt], mismatchMessage: String?) {
        let first = try act()
        guard first.verification == nil, risk <= .modify else {
            return ([first], nil)
        }
        reinspect()
        let second = try act()
        guard second.verification == nil else {
            return ([first, second], nil)
        }
        let outcome = second.verification == nil ? "still off" : "ok"
        let message =
            "I clicked \(title) expecting \(expected) but saw \(observed()). "
            + "Re-checked and tried once more — \(outcome)."
        return ([first, second], message)
    }
}

// MARK: - Self-test (owned; wired by the integrator)

/// Pure checks: no grant, no window, no network. The live capture path is exercised by
/// `--selftest-computer` / `--selftest-browser` (integration later); what is pinned
/// here is the policy that makes those tests meaningful.
enum ComputerVisionSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // Screenshot only after a stub tree — or when the model asked with a reason.
        let stub = "Window: Example\nstub tree, 0 names. No elements were invented."
        check("stub tree did not license a screenshot",
              ScreenshotPolicy.isNeeded(snapshotSummary: stub, reason: nil))
        check("a real tree licensed a screenshot without a reason",
              !ScreenshotPolicy.isNeeded(snapshotSummary: "Window: Example\nid: 1.1 button OK", reason: nil))
        check("an explicit reason was refused",
              ScreenshotPolicy.isNeeded(snapshotSummary: "Window: Example\nid: 1.1 button OK", reason: "seat-picker"))

        // Consent gate mirrors KnowledgeGraphScope: local readers pass, cloud needs
        // consent, nothing passes without an image.
        let fake = LLMImage(
            data: Data([0xFF, 0xD8]), mimeType: "image/jpeg",
            thumbnail: Data([0xFF, 0xD8]), pixelWidth: 2, pixelHeight: 1
        )
        check("nil image may send", !VisionScope.maySend(nil, consent: true))
        let local = VisionScope.$reader.withValue(.appleFoundation) {
            VisionScope.maySend(fake, consent: false)
        }
        check("local reader was gated by cloud consent", local)
        let cloudOff = VisionScope.$reader.withValue(.openRouter) {
            VisionScope.maySend(fake, consent: false)
        }
        check("cloud reader sent without consent", !cloudOff)
        let cloudOn = VisionScope.$reader.withValue(.openRouter) {
            VisionScope.maySend(fake, consent: true)
        }
        check("cloud reader with consent was blocked", cloudOn)
        check("image part built without consent", fake.contentPart(consent: false) == nil)

        // Pixel budget.
        let (wide, tall) = ScreenCapture.ScaledSize.fit(width: 2560, height: 1600, maxEdge: 1280)
        check("downscale broke the budget", wide == 1280 && tall == 800)
        let (smallW, smallH) = ScreenCapture.ScaledSize.fit(width: 800, height: 600, maxEdge: 1280)
        check("small capture was upscaled", smallW == 800 && smallH == 600)

        // Step-list wording the surface agent renders.
        check("step line wrong", VisionStepLine.sentScreenshot(1) == "sent 1 screenshot")

        // P1-4 fixture: first miss, then success — exactly two attempts, one success,
        // and no retry at all for a send.
        var calls = 0
        let fixtureResult = try? VerifyRetry.run(
            risk: .modify, title: "C2", expected: "C2 selected",
            observed: { "C1 selected" }, reinspect: {},
            act: {
                calls += 1
                return VerifyRetry.Attempt(
                    summary: "attempt \(calls)",
                    verification: calls >= 2 ? "Browser page reached the expected post-click state" : nil
                )
            }
        )
        let attempts = fixtureResult?.attempts ?? []
        // No `?? "threw"` fallback: optional chaining already flattens to `String?`, so
        // the default would replace the legitimate nil this very check is about.
        let message = fixtureResult?.mismatchMessage
        check("first-miss-then-succeed did not take exactly 2 attempts",
              calls == 2 && attempts.count == 2)
        check("a recovered retry still reported a mismatch", message == nil)
        check("a recovered retry lost its verification", attempts.last?.verification != nil)
        var sendCalls = 0
        let sendFixture = try? VerifyRetry.run(
            risk: .send, title: "Pay", expected: "receipt",
            observed: { "nothing" }, reinspect: {},
            act: {
                sendCalls += 1
                return VerifyRetry.Attempt(summary: "send attempt", verification: nil)
            }
        )
        let sendAttempts = sendFixture?.attempts ?? []
        check("a send was retried", sendCalls == 1 && sendAttempts.count == 1)

        for failure in failures {
            print("COMPUTER_VISION_CHECK_FAILED: \(failure)")
            Log.agent.error("computer-vision selftest: \(failure, privacy: .public)")
        }
        return failures.isEmpty
    }
}
