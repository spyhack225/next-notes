import Foundation

/// A short, truthful capability description for the on-device voice frontend.
///
/// The tool names come from `RealtimeAgent.plannableTools()`, which is the same
/// registry/allowlist used by the general tool loop. Building this is synchronous: it
/// reads cached app state and one synchronous Accessibility status query. It does not launch
/// a process, await an account probe, or prompt for a permission.
struct VoiceCapabilitySnapshot: Sendable, Equatable {
    enum WorkspaceStatus: Sendable, Equatable {
        case unknown
        case checking
        case notInstalled
        case needsOAuthClient
        case signedOut
        case signedIn(method: String)
        case failed(String)

        static func cached(_ state: WorkspaceAuthState, isProbing: Bool) -> Self {
            if isProbing { return .checking }
            switch state {
            case .notInstalled: return .notInstalled
            case .needsOAuthClient: return .needsOAuthClient
            case .signedOut: return .signedOut
            case .signedIn(let method): return .signedIn(method: method)
            case .failed(let reason): return .failed(reason)
            }
        }
    }

    struct Availability: Sendable, Equatable {
        /// `nil` means this process has not measured the permission.
        var accessibilityGranted: Bool?
        var workspace: WorkspaceStatus
        /// This setting controls post-meeting proposals, not direct voice tool calls.
        var automaticMeetingFollowUpsEnabled: Bool?

        init(
            accessibilityGranted: Bool? = nil,
            workspace: WorkspaceStatus = .unknown,
            automaticMeetingFollowUpsEnabled: Bool? = nil
        ) {
            self.accessibilityGranted = accessibilityGranted
            self.workspace = workspace
            self.automaticMeetingFollowUpsEnabled = automaticMeetingFollowUpsEnabled
        }
    }

    struct SelfTestResult: Sendable, Equatable {
        let passed: Bool
        let detail: String
    }

    /// Text intended to be inserted into the frontend's model context.
    let promptText: String
    /// The exact planner-visible ids represented by this snapshot.
    let toolIDs: [String]
    let availability: Availability

    /// Alias for callers that want the snapshot as a prompt section.
    var text: String { promptText }

    /// Introspection is application data. A semantic frontend decision selects
    /// this view; the model does not invent the roster or its availability.
    var spokenSummary: String {
        let ids = Set(toolIDs)
        var features: [String] = []
        if ids.contains("meeting.transcript") { features.append("read meeting transcripts and notes") }
        if ids.contains("get_agenda") { features.append("check your calendar") }
        if ids.contains("search_email") { features.append("search email") }
        if ids.contains("find_drive_files") { features.append("find Drive files") }
        if ids.contains("read_doc") { features.append("read Google documents") }
        if ids.contains("computer.inspect_ui") {
            features.append(ids.contains("computer.click") ? "inspect and control Mac apps" : "inspect Mac apps")
        }
        if ids.contains("browser.snapshot") {
            features.append(ids.contains("browser.click") ? "inspect and interact with browser pages" : "inspect browser pages")
        }
        if ids.contains("filesystem.read") {
            features.append(ids.contains("filesystem.write") ? "read and write local files" : "read local files")
        } else if ids.contains("filesystem.search") { features.append("search local files") }
        if ids.contains("shell.run") { features.append("run approved shell commands") }
        if ids.contains("memory.remember") { features.append("remember what you tell me about yourself") }
        if ids.contains("schedule.create") { features.append("set reminders") }
        guard !features.isEmpty else { return "No application tools are currently enabled." }
        var reply = "I can " + features.joined(separator: ", ") + "."
        var changes: [String] = []
        if ids.contains("create_event") { changes.append("calendar events") }
        if ids.contains("create_doc") { changes.append("documents") }
        if ids.contains("send_email") { changes.append("emails") }
        if !changes.isEmpty { reply += " I can prepare " + changes.joined(separator: ", ") + " for approval." }
        if ids.contains("get_agenda") || ids.contains("search_email") || ids.contains("find_drive_files") {
            switch availability.workspace {
            case .signedIn: break
            case .unknown, .checking, .failed:
                reply += " Google features require a connection that I haven't confirmed yet."
            case .notInstalled, .needsOAuthClient, .signedOut:
                reply += " Google features need connection setup."
            }
        }
        if ids.contains("computer.click"), availability.accessibilityGranted != true {
            reply += " App control needs Accessibility permission."
        }
        reply += ids.contains("memory.remember")
            ? " Changes and sends wait for your approval; memories save as you tell me them, and you can forget any in Settings."
            : " Changes and sends wait for your approval."
        return reply
    }

    /// Reads cached account state, the planner roster and current Accessibility status.
    /// No subprocess, account refresh or permission prompt runs here.
    @MainActor
    static func current(maxCharacters: Int = 1_650) -> Self {
        let service = AgentService.shared
        let workspace: WorkspaceStatus
        if service.isProbing {
            workspace = .checking
        } else if !service.hasCachedAuthStatus {
            workspace = .unknown
        } else {
            workspace = WorkspaceStatus.cached(service.authState, isProbing: false)
        }
        let availability = Availability(
            accessibilityGranted: Permissions.hasAccessibility,
            workspace: workspace,
            automaticMeetingFollowUpsEnabled: Settings.shared.agentEnabled
        )
        return make(
            tools: RealtimeAgent.plannableTools(),
            availability: availability,
            maxCharacters: maxCharacters
        )
    }

    /// Pure builder used by `current` and by self-tests with known registry/availability
    /// seams. The supplied tools should already be the planner's filtered roster.
    nonisolated static func make(
        tools: [AgentTool],
        availability: Availability = Availability(),
        maxCharacters: Int = 1_650
    ) -> Self {
        let orderedTools = tools.sorted { $0.id < $1.id }
        let toolIDs = orderedTools.map(\.id)
        var sections: [String] = ["Supported capabilities from the execution registry:"]

        // Keep evidence and the approval boundary at the front of the prompt. A bounded
        // context must never retain a list of names while dropping the state that qualifies
        // those names.
        sections.append("Accessibility: \(accessibilityLine(availability.accessibilityGranted)).")
        sections.append("Google Workspace: \(workspaceLine(availability.workspace)).")
        sections.append(
            "Reads follow Settings; changes, commands and sends require approval. "
                + "Support does not prove an account, target or permission is ready."
        )

        let categories: [(AgentToolNamespace, String, String)] = [
            (.meeting, "Meeting context", "Read transcripts and notes."),
            (.workspace, "Google Workspace", "Gmail, Calendar, Drive and Docs."),
            (.computer, "Frontmost Mac UI", "Inspect and control apps."),
            (.browser, "Browser pages", "Inspect and interact."),
            (.filesystem, "Local files", "Search, read and manage files."),
            (.shell, "Shell", "Run approved local commands."),
            (.memory, "Memory", "Remember, update and forget facts the user states; saves need no approval."),
            (.schedule, "Reminders", "Set, list, pause and delete reminders.")
        ]
        for (namespace, title, description) in categories {
            let names = orderedTools
                .filter { $0.namespace.rawValue == namespace.rawValue }
                .map(\.id)
            guard !names.isEmpty else { continue }
            sections.append("\(title): \(description) Tools: \(names.joined(separator: ", ")).")
        }

        return Self(
            promptText: bounded(sections, maxCharacters: maxCharacters),
            toolIDs: toolIDs,
            availability: availability
        )
    }

    /// Checks a supplied registry set without touching user history or external services.
    /// This catches drift between the realtime allowlist and the catalogue, and verifies
    /// that unavailable cached states do not render as connected/granted.
    nonisolated static func selfTest(
        tools: [AgentTool],
        availability: Availability = Availability()
    ) -> SelfTestResult {
        let ids = tools.map(\.id)
        let uniqueIDs = Set(ids)
        guard uniqueIDs.count == ids.count else {
            return SelfTestResult(passed: false, detail: "duplicate tool id")
        }

        // With memory turned off in Settings the planner roster leaves the memory tools out.
        var allowed = MemorySnapshotCache.shared.isEnabled
            ? RealtimeToolSelection.allowedIDs
            : RealtimeToolSelection.allowedIDs.subtracting(MemoryToolCatalogue.ids)
        // Likewise the reminder tools when reminders are switched off.
        if !ScheduleSettingsSnapshot.defaultsEnabled {
            allowed.subtract(ScheduleToolCatalogue.ids)
        }
        let missing = allowed.subtracting(uniqueIDs).sorted()
        guard missing.isEmpty else {
            return SelfTestResult(passed: false, detail: "missing allowed tools: \(missing.joined(separator: ", "))")
        }
        let outsideAllowlist = uniqueIDs.subtracting(allowed)
        guard outsideAllowlist.isEmpty else {
            return SelfTestResult(passed: false, detail: "roster contains unallowed tools: \(outsideAllowlist.sorted().joined(separator: ", "))")
        }

        let snapshot = make(tools: tools, availability: availability)
        if availability.accessibilityGranted == false,
           snapshot.promptText.contains("Accessibility: granted") {
            return SelfTestResult(passed: false, detail: "reported an ungranted Accessibility permission")
        }
        if case .signedIn = availability.workspace {
            // A signed-in status is the only state allowed to say connected.
        } else if snapshot.promptText.contains("Google Workspace: connected") {
            return SelfTestResult(passed: false, detail: "reported Workspace as connected without signed-in evidence")
        }
        return SelfTestResult(passed: true, detail: "\(ids.count) planner tools grounded")
    }

    private nonisolated static func accessibilityLine(_ granted: Bool?) -> String {
        switch granted {
        case true: "granted (current check)"
        case false: "not granted (current check)"
        case nil: "not checked"
        }
    }

    private nonisolated static func workspaceLine(_ status: WorkspaceStatus) -> String {
        switch status {
        case .unknown: "connection not checked"
        case .checking: "checking in the background; connection not yet confirmed"
        case .notInstalled: "the cached check did not find the Workspace CLI"
        case .needsOAuthClient: "the cached check found no OAuth client"
        case .signedOut: "not connected (cached)"
        case .signedIn: "connected (cached sign-in evidence)"
        case .failed: "connection check failed; availability unknown"
        }
    }

    private nonisolated static func followUpLine(_ enabled: Bool?) -> String {
        switch enabled {
        case true: "enabled in Settings"
        case false: "off in Settings"
        case nil: "setting not read"
        }
    }

    private nonisolated static func bounded(_ sections: [String], maxCharacters: Int) -> String {
        let limit = max(256, maxCharacters)
        var result = ""
        for section in sections {
            let candidate = result.isEmpty ? section : result + "\n" + section
            if candidate.count <= limit {
                result = candidate
                continue
            }

            // Preserve every category's heading under the normal budget, even if a caller
            // requests a very small bound. The complete ids remain available in `toolIDs`.
            let description = section.components(separatedBy: " Tools:").first ?? section
            let compact = result.isEmpty ? String(section.prefix(limit)) : description
            let withCompact = result.isEmpty ? compact : result + "\n" + compact
            if withCompact.count <= limit { result = withCompact }
        }
        return result
    }
}
