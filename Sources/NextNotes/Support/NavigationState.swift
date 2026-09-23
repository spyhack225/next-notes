import Foundation
import Observation

/// The sidebar sections of the main window.
enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case dictation
    case meetings
    /// Search across the knowledge index. Listed only while the index is on.
    case search
    case agent
    case dictionary
    case comparison

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .meetings: "Meetings"
        case .search: "Search"
        case .agent: "Agent"
        case .dictionary: "Dictionary"
        case .comparison: "Comparison"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "waveform"
        case .meetings: "person.2.wave.2"
        case .search: "text.magnifyingglass"
        case .agent: "ear"
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

    /// Which pane the Settings window shows.
    ///
    /// Shared rather than local to that window so a screen that has diagnosed a problem can
    /// open the pane that fixes it. Not persisted: where Settings was last is a detail of a
    /// window that is usually closed, and reopening on General is the least surprising.
    var selectedSettingsTab: SettingsTab = .general

    /// Which pane the Agent section shows. Not persisted: the conversation is home.
    ///
    /// The graph lives here rather than under Search because it is the assistant's picture of
    /// the user's life and their Mac — people, projects, places and the folders on disk — not
    /// a way of finding a sentence someone said. Search kept search.
    enum AgentPane: String, CaseIterable, Identifiable {
        case conversation
        /// Out-of-box suggestions that open a setup flow — never execute (G2).
        case ideas
        /// Outcomes the person is working toward (G1): their state and their nudges.
        case goals
        /// What the graph says about the person's week: Corners' cards, and the Portrait
        /// sentences waiting to be kept or crossed out (P2-1, P2-2).
        case portrait
        /// What runs and when: reminders, recurring runs, triggers, drafts awaiting
        /// approval and suggestions. Goals are what you are working toward; this pane is
        /// what the assistant does about them.
        case reminders
        /// Cross-session history, the approvals ledger and the heartbeat (§8.2).
        case activity
        case graph
        case skills
        case about

        var id: String { rawValue }

        /// The consumer name of the pane, and the text every control that picks or names
        /// one draws. It must never be empty: the toolbar picker shows exactly this, and
        /// an empty title is the chevron-only pill this replaced.
        var title: String {
            switch self {
            case .conversation: "Conversation"
            case .ideas: "Ideas"
            case .goals: "Goals"
            case .portrait: "Portrait"
            case .reminders: "Reminders"
            case .activity: "Activity"
            case .graph: "Graph"
            case .skills: "Skills"
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
        selectedSection = SidebarSection(rawValue: raw) ?? .dictation
    }

    func show(_ section: SidebarSection) {
        selectedSection = section
    }

    /// Agent → Reminders, from a reminder or run notification.
    func showRoutines() {
        selectedSection = .agent
        agentPane = .reminders
    }

    /// Agent → About (SOUL, MEMORY, name and avatar), from Settings or a deep link.
    func showAgentAbout() {
        selectedSection = .agent
        agentPane = .about
    }

    /// Agent → Graph. The graph used to be a mode of Search, so anything that pointed at it —
    /// a deep link, a search result, a Settings button — comes through here and keeps working.
    func showGraph() {
        selectedSection = .agent
        agentPane = .graph
    }

    /// Agent → Skills.
    func showSkills() {
        selectedSection = .agent
        agentPane = .skills
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
