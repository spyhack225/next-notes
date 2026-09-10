import Foundation
import Observation

/// The sidebar sections of the main window.
enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case dictation
    case meetings
    case dictionary
    case comparison

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        case .dictionary: "Dictionary"
        case .comparison: "Comparison"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "waveform"
        case .meetings: "person.2.wave.2"
        case .dictionary: "character.book.closed"
        case .comparison: "rectangle.split.2x1"
        }
    }
}

/// Where the main window is, shared so the app delegate and URL handler can steer it
/// without SwiftUI's environment. Persisted so a `make install` relaunch lands where you
/// were.
@MainActor
@Observable
final class NavigationState {
    static let shared = NavigationState()

    var selectedSection: SidebarSection {
        didSet { UserDefaults.standard.set(selectedSection.rawValue, forKey: Keys.section) }
    }

    /// The meeting shown in the Meetings detail column, if any.
    var selectedMeetingID: UUID?

    /// Which tab the Settings window shows.
    ///
    /// Shared rather than local to that window so a screen that has diagnosed a problem can
    /// open the tab that fixes it. Not persisted: where Settings was last is a detail of a
    /// window that is usually closed, and reopening on General is the least surprising.
    var selectedSettingsTab: SettingsTab = .general

    private enum Keys {
        static let section = "navigation.section"
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.section) ?? ""
        selectedSection = SidebarSection(rawValue: raw) ?? .dictation
    }

    func show(_ section: SidebarSection) {
        selectedSection = section
    }

    func show(meeting id: UUID) {
        selectedSection = .meetings
        selectedMeetingID = id
    }
}
