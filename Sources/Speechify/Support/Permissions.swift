import AVFoundation
import AppKit
import CoreGraphics
import ApplicationServices
import EventKit
import Foundation

/// Every grant Speechify can ask for, and where to send the user when it can't ask.
///
/// - **Microphone** — dictation and the "you" track of a meeting.
/// - **Accessibility** — the `CGEventTap` hotkey and the AX text insert. No programmatic
///   request exists; the OS shows a prompt and the user toggles it in System Settings.
/// - **System audio** — the Core Audio process tap that hears the other side of a meeting.
///   macOS folds audio-only taps into the same grant as screen recording, "Screen & System
///   Audio Recording", so the CoreGraphics screen-capture calls are what answers for it and
///   what prompts for it. That coupling is Apple's, not ours.
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

    /// Whether the process tap will carry real audio rather than silence.
    ///
    /// There is no query API for the tap itself, which is why this used to be unanswerable
    /// and the checklist row simply had no state. It is answerable through the front door
    /// instead: macOS gates audio-only taps on "Screen & System Audio Recording", the same
    /// grant screen capture uses, so its preflight is the tap's answer too.
    ///
    /// The ground truth is still the tap. Without the grant a tap succeeds, delivers frames,
    /// and every sample is zero — measured on 2026-09-09, which is why `--selftest-systemaudio`
    /// reports the zeroed-frame case in so many words rather than trusting this bit.
    static var hasSystemAudio: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks for it, so the checklist can prompt inline like every other row.
    ///
    /// Prompts once per install; afterwards it returns the standing answer and the Settings
    /// pane is the only way to change it, so a refusal sends the user there.
    @discardableResult
    static func requestSystemAudio() -> Bool {
        CGRequestScreenCaptureAccess()
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
    /// one lands on a page that does not list Speechify at all.
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
