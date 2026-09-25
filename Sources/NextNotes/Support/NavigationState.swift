import Foundation
import Observation

/// The sidebar sections of the main window, in the order they are drawn.
///
/// The Agent's own panes are destinations here — Graph, Portrait, Idea, Goals, Reminders,
/// Skills — because they are places to go, not modes of the conversation. The Agent
/// section's tab row keeps the three that are read *with* the conversation: Conversation,
/// Activity and About.
///
/// Two cases are not rows: `comparison` is retired (it is a Settings pane now) and
/// `settings` is the row drawn below the group. `CaseIterable` cannot express "every case
/// except these two", so `Sidebar.visibleSections` does that, and both stay here so a
/// stored raw value keeps decoding.
enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case agent
    case meetings
    case dictation
    case graph
    case portrait
    case ideas
    case goals
    case reminders
    case skills
    /// Search across the knowledge index. Listed only while the index is on.
    case search
    case dictionary
    /// Retired from the spine; Comparison moved into Settings. Kept so a machine left on
    /// the old row keeps decoding, and `NavigationState` opens the pane that replaced it.
    case comparison
    /// The in-app way into Settings. Drawn below the section group, never persisted.
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent: "Agent"
        case .meetings: "Meeting"
        case .dictation: "Dictation"
        case .graph: "Graph"
        case .portrait: "Portrait"
        case .ideas: "Idea"
        case .goals: "Goals"
        case .reminders: "Reminders"
        case .skills: "Skills"
        case .search: "Search"
        case .dictionary: "Dictionary"
        case .comparison: "Comparison"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "ear"
        case .meetings: "person.2.wave.2"
        case .dictation: "waveform"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .portrait: "person.text.rectangle"
        case .ideas: "lightbulb"
        case .goals: "target"
        case .reminders: "calendar.badge.clock"
        case .skills: "books.vertical"
        case .search: "text.magnifyingglass"
        case .dictionary: "character.book.closed"
        case .comparison: "rectangle.split.2x1"
        case .settings: "gearshape"
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
        didSet {
            // The Settings row is a way in, not where the window reopens: a machine quit
            // while looking at Settings comes back to the section it was working in.
            // `comparison` is guarded for the same reason — it has no row, and a value
            // stored before the move is replaced at launch rather than restored.
            guard selectedSection != .settings, selectedSection != .comparison else { return }
            UserDefaults.standard.set(selectedSection.rawValue, forKey: Keys.section)
        }
    }

    /// The meeting shown in the Meetings detail column, if any.
    var selectedMeetingID: UUID?

    /// Which pane the Settings window shows.
    ///
    /// Shared rather than local to that window so a screen that has diagnosed a problem can
    /// open the pane that fixes it. Not persisted: where Settings was last is a detail of a
    /// window that is usually closed, and reopening on General is the least surprising.
    var selectedSettingsTab: SettingsTab = .general

    /// Which tab the Agent section shows. Three only, and that is the layout rule: the
    /// conversation and the two panels read beside it. The rest of the old panes — Ideas,
    /// Goals, Portrait, Reminders, Graph, Skills — are `SidebarSection` destinations of
    /// their own, because they are places to go rather than modes of the conversation.
    enum AgentPane: String, CaseIterable, Identifiable {
        case conversation
        /// Cross-session history, the approvals ledger and the heartbeat (§8.2).
        case activity
        case about

        var id: String { rawValue }

        /// The consumer name of the pane, and the text every control that picks or names
        /// one draws. It must never be empty: the tab row shows exactly this, and an empty
        /// title is the chevron-only pill this replaced.
        var title: String {
            switch self {
            case .conversation: "Conversation"
            case .activity: "Activity"
            case .about: "About"
            }
        }
    }

    var agentPane: AgentPane = .conversation

    /// A memory the graph asked to open, read and cleared by the Memories sheet when it
    /// appears. A `memory:` dot is a fact the user can change, not a place to explore, so
    /// clicking one comes here instead of focusing a neighbourhood.
    private(set) var pendingMemory: UUID?

    /// Agent → About, with the Memories sheet opening on one fact.
    func openMemories(_ memoryID: UUID?) {
        pendingMemory = memoryID
        showAgentAbout()
    }

    /// The memory waiting to be shown, consumed exactly once.
    func consumePendingMemory() -> UUID? {
        defer { pendingMemory = nil }
        return pendingMemory
    }

    private enum Keys {
        static let section = "navigation.section"
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Keys.section) ?? ""
        var restored = SidebarSection(rawValue: raw) ?? .dictation

        // Comparison moved into Settings. A machine left on the old row opens the pane
        // that replaced it, once — Settings, showing Comparison — and the retired value is
        // then replaced with Dictation so the next launch does not reopen Settings. A
        // stored `settings` could only come from a build that persisted the row, which
        // this one does not.
        if restored == .comparison {
            selectedSettingsTab = .comparison
            restored = .settings
        } else if restored == .settings {
            restored = .dictation
        }
        selectedSection = restored
        // `settings` is deliberately not written back: the migration lands there once, and
        // the next launch must come back to a real section rather than reopen Settings.
        if raw != restored.rawValue, restored != .settings {
            UserDefaults.standard.set(restored.rawValue, forKey: Keys.section)
        }
    }

    func show(_ section: SidebarSection) {
        // Comparison is a Settings pane now; anything still steering at the retired
        // section — the `nextnotes://show` deep link — lands on the pane that replaced it.
        if section == .comparison {
            showComparison()
            return
        }
        selectedSection = section
    }

    /// Settings → Comparison. The screen used to be a sidebar section of its own.
    func showComparison() {
        selectedSettingsTab = .comparison
        selectedSection = .settings
    }

    /// Reminders, from a reminder or run notification. It is its own sidebar section now,
    /// so this is a place to go rather than a tab of the Agent.
    func showRoutines() {
        selectedSection = .reminders
    }

    /// Agent → About (SOUL, MEMORY, name and avatar), from Settings or a deep link.
    func showAgentAbout() {
        selectedSection = .agent
        agentPane = .about
    }

    /// Graph. The graph used to be a mode of Search, then a pane of the Agent; anything
    /// that pointed at it — a deep link, a search result, a Settings button — comes through
    /// here and keeps working.
    func showGraph() {
        selectedSection = .graph
    }

    /// Skills.
    func showSkills() {
        selectedSection = .skills
    }

    /// A moment in a meeting's transcript that a search result jumped to. The token makes a
    /// second jump to the same second a change the transcript notices.
    struct TranscriptFocus: Equatable {
        let meetingID: UUID
        let time: TimeInterval
        var token = UUID()
    }

    /// Where the Meetings detail should open its transcript, if a search result asked.
    var transcriptFocus: TranscriptFocus?

    func show(meeting id: UUID) {
        selectedSection = .meetings
        selectedMeetingID = id
        transcriptFocus = nil
    }

    /// Meetings → this meeting → Transcript, scrolled to `time`.
    func show(meeting id: UUID, at time: TimeInterval) {
        selectedSection = .meetings
        selectedMeetingID = id
        transcriptFocus = TranscriptFocus(meetingID: id, time: time)
    }

    /// Agent → Conversation.
    func showConversation() {
        selectedSection = .agent
        agentPane = .conversation
    }
}
