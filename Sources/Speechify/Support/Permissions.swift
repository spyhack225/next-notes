import AVFoundation
import AppKit
import ApplicationServices
import EventKit
import Foundation

/// Every grant Speechify can ask for, and where to send the user when it can't ask.
///
/// - **Microphone** — dictation and the "you" track of a meeting.
/// - **Accessibility** — the `CGEventTap` hotkey and the AX text insert. No programmatic
///   request exists; the OS shows a prompt and the user toggles it in System Settings.
/// - **System audio** — the Core Audio process tap that hears the other side of a meeting.
///   The OS prompts on first use of the tap; there is no query API, so `SystemAudioCapture`
///   probes by trying.
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

    static func openSystemAudioSettings() {
        open("Privacy_AudioCapture")
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
