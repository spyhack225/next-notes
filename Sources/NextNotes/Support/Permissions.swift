import AVFoundation
import AppKit
import ApplicationServices
import EventKit
import Foundation
import os

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
/// - **Full Disk Access** — reading the Messages database for remote access. Apple ships no
///   API that reads received messages, and `chat.db` is world-readable yet still returns
///   `authorization denied` without this, so the only proof available is a row actually
///   being read. No request API, like Accessibility: the row opens the pane.
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

    /// Whether a system-audio tap in this app has ever delivered real sound.
    ///
    /// Evidence, not a query — the grant still cannot be read. A tap without the grant
    /// succeeds and delivers zeroed samples, so one non-silent buffer is proof the grant
    /// exists, and it is the only proof there is. On 2026-09-20 the user switched the grant
    /// on in both lists of the pane and the row went on saying "Ask…", which read as broken.
    /// The reverse is not evidence: silence is also what a quiet Mac sounds like.
    nonisolated static var hasHeardSystemAudio: Bool {
        UserDefaults.standard.object(forKey: systemAudioHeardKey) != nil
    }

    private nonisolated static let systemAudioHeardKey = "permissions.systemAudioHeardAt"
    private nonisolated static let heardThisLaunch = OSAllocatedUnfairLock(initialState: false)

    /// Called from the tap's audio thread on a non-silent buffer. Writes once per launch.
    nonisolated static func noteSystemAudioHeard() {
        let first = heardThisLaunch.withLock { heard -> Bool in
            defer { heard = true }
            return !heard
        }
        guard first else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: systemAudioHeardKey)
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

        // Startup runs off the main actor because the HAL can synchronously wait for a
        // device. Keep the probe alive briefly after completion so macOS can raise its
        // permission prompt, then tear down the private tap.
        Task { @MainActor in
            do {
                try await capture.start(outputFormat: format, onBuffer: { _ in }, onLevel: { _ in })
            } catch {
                Log.systemAudio.error("tap probe failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Long enough to catch a beat of whatever is playing, which is what turns the
            // row green; the prompt itself needs far less.
            try? await Task.sleep(for: .milliseconds(1_500))
            capture.stop()
        }
    }

    /// Whether this process can read a row out of the Messages database — which is the only
    /// way to know whether Full Disk Access is granted, because that grant has no query API
    /// either. A thin read of `MessagesDatabaseHealth`, kept here so this file stays the one
    /// place a caller looks for "can I do the thing", and the reason it is a `func` and not
    /// a `var` is the reason the probe is not free: it opens a file Messages owns.
    static func hasMessagesAccess() async -> Bool {
        await MessagesDatabaseHealth.probe().isReadable
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

    /// Desktop / Documents / Downloads for an app outside the sandbox. A folder refused
    /// here fails every read afterwards, and this pane is the only way back.
    static func openFilesAndFoldersSettings() {
        open("Privacy_FilesAndFolders")
    }

    /// Full Disk Access, and the only way to reach it: there is no prompt, no preflight and
    /// no `AXIsProcessTrusted`-shaped equivalent, so the only honest thing a button can do
    /// is put the person in the pane where the switch is. Which is why
    /// `MessagesDatabaseHealth.canRequest` is `false` and why the row that leads here is
    /// shaped like Accessibility's rather than like the microphone's.
    static func openFullDiskAccessSettings() {
        open("Privacy_AllFiles")
    }

    /// What to tell somebody whose Accessibility switch is on and who still is not trusted.
    ///
    /// TCC stores a code-signing requirement beside each grant, so an entry made against a
    /// previous build keeps its switch on while `AXIsProcessTrusted()` stays false and the
    /// event tap refuses to arm. Nothing in the API distinguishes that from "not granted"
    /// — the only tell is a switch the user says is on next to a tap that will not start —
    /// so the repair is offered rather than detected, in the words of somebody who has
    /// never heard of a code signature.
    ///
    /// One string, here, because the first-run screen and the Settings tab both say it and
    /// they must not drift.
    /// `nonisolated` because a constant sentence needs no actor, and the value that decides
    /// what the last setup screen says (`OnboardingOutcome`) is deliberately not one.
    nonisolated static let accessibilityRepairAdvice =
        "If the switch next to Next Notes already looks on, macOS is holding on to an older "
        + "copy of it. Select Next Notes in that list, press the minus button to remove it, "
        + "then press plus and add Next Notes again."

    /// Full Disk Access is the one pane where the app is **not already listed**, so the button
    /// opens a list with no Next Notes in it and no switch to flip. Every other row's advice
    /// would be wrong here: the instruction people need is the one everybody misses, which is
    /// that the `+` button is the whole task.
    ///
    /// `nonisolated` for the same reason as the accessibility string above — a constant
    /// sentence needs no actor, and the Messages row, the Settings section and any first-run
    /// screen all have to say the same words rather than three versions of them.
    nonisolated static let fdaAddAdvice =
        "Next Notes isn't in that list yet. Press the + button below the list, choose "
        + "Applications, then click Next Notes."

    /// The same stale-entry failure the accessibility row has, reached a different way: a
    /// Full Disk Access entry is a *path*, so an entry made against an earlier build keeps its
    /// switch on while the database stays unreadable. From inside the app the two cases are
    /// indistinguishable — the probe reads a row or it does not — so this is offered after a
    /// press rather than detected, which is the honest shape and the one the accessibility row
    /// already established.
    nonisolated static let fdaRepairAdvice =
        "If Next Notes is already in that list with its switch on and this still says it is "
        + "not, macOS is holding on to an older copy of it. Select Next Notes, press the minus "
        + "button to remove it, then press plus and add it again."

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
