import AppKit
import Foundation
import Observation

/// "Use your Google account on this Mac": where it has got to, and the one thing to do next.
///
/// One model for every screen that offers it — the Workspace tab, the permissions list and
/// first run — so they cannot give three different answers about the same account. It reads
/// `MacSetup` (a value) and turns it into a plain sentence and one button.
@MainActor
@Observable
final class MacAccountModel {
    static let shared = MacAccountModel()

    private(set) var setup: MacSetup?
    private(set) var isWorking = false

    /// What a screen draws for a step. Pure, so a test reads every row, and no row has a
    /// word a person would not say out loud.
    struct Presentation: Equatable, Sendable {
        let label: String
        let button: String?
        let detail: String
    }

    nonisolated static func presentation(for step: MacSetup.Step?) -> Presentation {
        switch step {
        case nil, .allowCalendar?:
            Presentation(
                label: "Not connected",
                button: "Use your Google account on this Mac",
                detail: "I\u{2019}ll read your mail and calendar from the Google account already on this Mac. "
                    + "Nothing is sent until you say so.")
        case .openCalendarSettings?:
            Presentation(
                label: "One switch to flip",
                button: "Open Calendar settings\u{2026}",
                detail: "Next Notes can\u{2019}t see your calendar yet. Switch it on for Next Notes, then come back.")
        case .addAccount?:
            Presentation(
                label: "No Google account found",
                button: "Add your Google account\u{2026}",
                detail: "There\u{2019}s no Google account on this Mac yet. Add one in Internet Accounts with Mail and "
                    + "Calendars switched on, then come back.")
        case .allowMailAccess?:
            Presentation(
                label: "Almost there",
                button: "Allow reading your mail\u{2026}",
                detail: "To read your mail, switch on Full Disk Access for Next Notes. "
                    + "The same switch covers the iMessage chat you choose.")
        case .turnOnMail?:
            Presentation(
                label: "Almost there",
                button: "Open Internet Accounts\u{2026}",
                detail: "Your Google account is here, but Mail isn\u{2019}t switched on for it. Turn Mail on, then come back.")
        case .ready?:
            Presentation(
                label: "Connected",
                button: nil,
                detail: "Using the Google account on this Mac. Nothing is sent without your yes.")
        }
    }

    var step: MacSetup.Step? { setup?.nextStep }
    var presentation: Presentation { Self.presentation(for: step) }
    var isConnected: Bool { step == .ready }

    func refresh() async {
        guard !SelfTest.isRunning else { return }
        setup = await MacAccounts.shared.setup()
    }

    /// The one button. It records the choice (so an unset source becomes this Mac) and then does
    /// the next step: ask the system, or open the pane where the switch is.
    func act() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let settings = Settings.shared
        if settings.googleSource != .thisMac {
            settings.googleSource = .thisMac
            GoogleSource.forget()
        }
        if setup == nil { await refresh() }
        switch step ?? .allowCalendar {
        case .allowCalendar: _ = await MacAccounts.shared.requestCalendarAccess()
        case .openCalendarSettings: Permissions.openCalendarSettings()
        case .addAccount, .turnOnMail: Self.openInternetAccounts()
        case .allowMailAccess: Permissions.openFullDiskAccessSettings()
        case .ready: break
        }
        await refresh()
        AgentService.shared.invalidateStatus()
        await AgentService.shared.refreshStatus(force: true)
    }

    static func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
