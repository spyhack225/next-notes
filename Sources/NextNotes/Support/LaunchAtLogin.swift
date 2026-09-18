import Foundation
import ServiceManagement

/// Open Next Notes at login, through `SMAppService.mainApp` (Part 3, open decision 2).
///
/// Routines need the app running to use tools; without this, every routine silently stops
/// when the app is not open. The recommended default is *offered once the first routine
/// exists* and off until the user turns it on — so this never registers anything by
/// itself. `Settings.agentLaunchAtLogin` records the user's choice; `apply` makes macOS
/// match it.
@MainActor
enum LaunchAtLogin {
    /// Whether macOS currently has the app registered to open at login.
    static var isRegistered: Bool {
        guard !SelfTest.isRunning else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters to match `enabled`. Returns a problem to show, or nil.
    @discardableResult
    static func apply(_ enabled: Bool) -> String? {
        guard !SelfTest.isRunning else { return nil }
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return nil }
                try service.register()
                if service.status == .requiresApproval {
                    return "macOS needs your approval in System Settings → General → Login Items."
                }
            } else {
                guard service.status == .enabled || service.status == .requiresApproval else { return nil }
                try service.unregister()
            }
            return nil
        } catch {
            Log.app.error("launch at login: \(error.localizedDescription, privacy: .public)")
            return "Couldn't change Open at login: \(error.localizedDescription)"
        }
    }

    /// The offer made when a routine is created: only for the first one, and only while the
    /// setting is still off. Pure, so the self-test checks it.
    static func offer(routineCount: Int, enabled: Bool) -> String? {
        guard routineCount == 1, !enabled else { return nil }
        return "Routines only run while Next Notes is open. Offer to turn on Open at login "
            + "(Settings → Agent → Reminders and routines); it stays off unless the user says yes."
    }
}
