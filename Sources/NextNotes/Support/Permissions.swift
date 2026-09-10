import AVFoundation
import AppKit
import ApplicationServices
import EventKit
import Foundation

/// Every grant Next Notes can ask for, and where to send the user when it can't ask.
///
/// - **Microphone** — dictation and the "you" track of a meeting.
/// - **Accessibility** — the `CGEventTap` hotkey and the AX text insert. No programmatic
///   request exists; the OS shows a prompt and the user toggles it in System Settings.
/// - **System audio** — the Core Audio process tap that hears the other side of a meeting.
///   It lives in the "Screen & System Audio Recording" pane but in that pane's *second*
///   list, "System Audio Recording Only", which is a different grant from screen recording
///   and has no query API. macOS decides on first use of a tap, so it cannot be read, only
///   provoked and then measured.
/// - **Calendar** — EventKit, for meeting detection. Google Calendar is OAuth, not TCC.
///
/// TCC keys every grant on the code signature, so re-signing the app resets them.
@MainActor
enum Permissions {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var hasCalendar: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Nudges macOS into asking for system audio, by doing the thing it asks about.
    ///
    /// There is no preflight and no request API for an audio-only process tap. macOS decides
    /// on first use of a tap, so the only way to raise the prompt is to open one and throw it
    /// away — which is what this does.
    ///
    /// **Do not reach for `CGPreflightScreenCaptureAccess` here.** It looks like the answer,
    /// because the pane is called "Screen & System Audio Recording" and the tap's own error
    /// points at it. It is not: that pane holds two separate lists, and an app granted
    /// "System Audio Recording Only" captures audio perfectly while screen-capture preflight
    /// keeps returning false. Measured on 2026-09-09 — a tap returning `rms 0.17489,
    /// peak 0.75562` in the same process where the preflight said no.
    ///
    /// Nothing is returned because nothing truthful can be. A tap without the grant still
    /// succeeds and still delivers frames; it just zeroes every sample, so "did it work" can
    /// only be answered while something is playing. `--selftest-systemaudio` is that answer.
    static func requestSystemAudio() {
        let capture = SystemAudioCapture()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return }

        do {
            try capture.start(outputFormat: format, onBuffer: { _ in }, onLevel: { _ in })
        } catch {
            Log.systemAudio.error("tap probe failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Long enough for the tap to exist and the prompt to be raised, short enough that
        // nothing downstream has to care that it happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { capture.stop() }
    }

    /// Shows the system Accessibility prompt if the app isn't yet trusted.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        // Spelled out rather than using `kAXTrustedCheckOptionPrompt`, which imports as a
        // mutable global and so isn't usable from concurrency-checked code.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// The store that asks for calendar access, kept alive for the life of the process.
    ///
    /// EventKit delivers its answer to the store that asked, and a store created inline for
    /// the call is a temporary: it can be released while the prompt is still on screen,
    /// which resolves the request as a refusal without the user having touched anything —
    /// and leaves the app absent from the Calendars list, so there is nothing to switch on
    /// afterwards either.
    private static let eventStore = EKEventStore()

    static func requestCalendar() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                Log.calendar.info("calendar access \(granted ? "granted" : "refused", privacy: .public)")
                return granted
            } catch {
                // Swallowed with `try?` once, which is why "nothing happens when I press
                // Grant" had no explanation anywhere.
                Log.calendar.error("calendar access request failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        default:
            // Already answered, and macOS only ever prompts once — so the honest next step
            // is System Settings, which is what every caller does with `false`.
            Log.calendar.info("calendar access already decided: \(String(describing: status), privacy: .public)")
            return false
        }
    }

    static func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("Privacy_Microphone")
    }

    /// `Privacy_ScreenCapture`, not `Privacy_AudioCapture`. The grant lives in the combined
    /// "Screen & System Audio Recording" pane, which is the screen-capture anchor; the audio
    /// one lands on a page that does not list Next Notes at all.
    static func openSystemAudioSettings() {
        open("Privacy_ScreenCapture")
    }

    static func openCalendarSettings() {
        open("Privacy_Calendars")
    }

    /// Notifications are not a privacy pane: they live in their own Settings extension, so
    /// the security URL every other row uses opens the wrong page.
    static func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func open(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
