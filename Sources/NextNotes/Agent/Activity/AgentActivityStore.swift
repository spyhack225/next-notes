import Foundation
import Observation

/// One row of a run's step list (P1-1). `title` is a consumer step title — what the
/// `AgentActivityProjector` produced — never a tool id and never chain-of-thought.
struct AgentStep: Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var detail: String
    var isCompleted: Bool
    /// What the avatar was doing while this step ran, when the tool layer said. Carried per
    /// step rather than read from the store's live state so a working card shows *its* run
    /// — two tasks can overlap, and the newest is not always the one on screen.
    var avatar: AgentAvatarState?

    init(
        id: String = UUID().uuidString,
        title: String,
        detail: String = "",
        isCompleted: Bool = false,
        avatar: AgentAvatarState? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isCompleted = isCompleted
        self.avatar = avatar
    }
}

@MainActor
@Observable
final class AgentActivityStore {
    static let shared = AgentActivityStore()

    private(set) var activities: [AgentActivity] = []
    /// Ordered steps per task, oldest first. Steps are appended, never replaced: the
    /// island's `n/m` counter and the working card's ✓/◐ rows both read this (P1-1).
    private(set) var taskSteps: [String: [AgentStep]] = [:]
    /// The task whose steps the live surfaces show — the most recent one that began and
    /// has not finished. Nil when nothing is working.
    private(set) var activeTaskID: String?
    /// What the agent's avatar is doing right now, if anything.
    ///
    /// Kept here rather than inferred from `liveSteps` because the two know different
    /// things: the step feed is titles for a person, and the avatar state is a decision
    /// the tool layer made (`AgentAvatarState.forTool`) about the thing that is actually
    /// running. A view that read the titles back would be guessing at wording it does not
    /// own — the same reason the projector exists at all.
    private(set) var liveAvatarState: AgentAvatarState?

    private init() {}

    func begin(task: AgentTask, title: String) {
        append(AgentActivity(taskID: task.id, kind: .thinking, title: title))
        taskSteps[task.id] = []
        activeTaskID = task.id
        liveAvatarState = .thinking
    }

    func update(
        taskID: String,
        kind: AgentActivityKind,
        title: String,
        detail: String = "",
        avatar: AgentAvatarState? = nil
    ) {
        append(AgentActivity(taskID: taskID, kind: kind, title: title, detail: detail))
        var steps = taskSteps[taskID] ?? []
        if !steps.isEmpty { steps[steps.count - 1].isCompleted = true }
        let state = avatar ?? AgentAvatarState(activity: kind)
        steps.append(AgentStep(title: title, detail: detail, avatar: state))
        taskSteps[taskID] = steps
        liveAvatarState = state
    }

    func finish(taskID: String, title: String) {
        append(AgentActivity(taskID: taskID, kind: .completed, title: title))
        if var steps = taskSteps[taskID], !steps.isEmpty {
            steps[steps.count - 1].isCompleted = true
            taskSteps[taskID] = steps
        }
        if activeTaskID == taskID { activeTaskID = nil }
        liveAvatarState = nil
    }

    func append(_ activity: AgentActivity) {
        activities.insert(activity, at: 0)
        if activities.count > 80 { activities = Array(activities.prefix(80)) }
    }

    // MARK: - Step list (P1-1)

    /// The running task's steps, oldest first. The self-test fixture and the working
    /// card both read this; filtering by `activeTaskID` is what keeps a finished run's
    /// rows off the live surfaces ("running-task filtered").
    func steps(taskID: String) -> [AgentStep] {
        taskSteps[taskID] ?? []
    }

    /// The island's feed: step titles and the 1-based number of the one in progress.
    /// At most one step is ever in progress — the newest unfinished one.
    var liveSteps: (titles: [String], current: Int, total: Int) {
        guard let id = activeTaskID, let steps = taskSteps[id], !steps.isEmpty else {
            return ([], 0, 0)
        }
        let titles = steps.map(\.title)
        let completed = steps.count(where: \.isCompleted)
        let current = min(completed + 1, steps.count)
        return (titles, current, steps.count)
    }

    /// How many steps are in progress right now. `--selftest-island`'s 4-step fixture
    /// asserts this is exactly one for a scripted run.
    var inProgressStepCount: Int {
        guard let id = activeTaskID, let steps = taskSteps[id] else { return 0 }
        return steps.count { !$0.isCompleted }
    }

    /// The step-list line that says a screenshot was uploaded (P1-2). The wording comes
    /// from `VisionStepLine` so the consent sheet, the step list and the Activity screen
    /// all say the same sentence. Called when the person's yes lets a capture leave the
    /// Mac; a task with no live run is a no-op.
    func noteScreenshotSent(taskID: String? = nil, count: Int = 1) {
        guard let id = taskID ?? activeTaskID else { return }
        update(taskID: id, kind: .reading, title: VisionStepLine.sentScreenshot(count))
    }

    /// Clears the step feed between self-test fixtures. Never called in production.
    func resetForSelfTest() {
        taskSteps = [:]
        activeTaskID = nil
        liveAvatarState = nil
    }
}

@MainActor
@Observable
final class AgentAuditLog {
    static let shared = AgentAuditLog()

    private(set) var entries: [AgentAuditEntry] = []

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("agent-audit.jsonl")
    }

    private init() {
        // A self-test neither writes nor reads the user's audit log.
        entries = SelfTest.isRunning ? [] : Self.load()
    }

    func record(
        kind: AgentAuditEntry.Kind,
        title: String,
        detail: String = "",
        toolID: String? = nil,
        taskID: String? = nil,
        meetingID: UUID? = nil,
        scheduleID: UUID? = nil,
        triggerQuote: String? = nil
    ) {
        // Self-tests may inspect the in-memory audit trail (see `--selftest-tasks`),
        // but must never write fixture text into the person's persistent history —
        // the same split ActionReceiptStore uses.
        let entry = AgentAuditEntry(
            kind: kind,
            title: title,
            detail: detail,
            toolID: toolID,
            taskID: taskID,
            meetingID: meetingID,
            scheduleID: scheduleID,
            triggerQuote: triggerQuote
        )
        entries.insert(entry, at: 0)
        if entries.count > 400 { entries = Array(entries.prefix(400)) }
        guard !SelfTest.isRunning else { return }
        appendToDisk(entry)
    }

    private func appendToDisk(_ entry: AgentAuditEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if FileManager.default.fileExists(atPath: Self.fileURL.path),
           let handle = try? FileHandle(forWritingTo: Self.fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: Self.fileURL, options: .atomic)
        }
    }

    private static func load() -> [AgentAuditEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").reversed().compactMap { line in
            try? decoder.decode(AgentAuditEntry.self, from: Data(line.utf8))
        }
    }

    /// Cross-session history for `ActivityView` (§8.2): the persisted log grouped by
    /// day, newest day first. Self-tests see only the in-memory entries.
    static func loadPersistedGroupedByDay(
        now: Date = Date(),
        dayCount: Int = 14
    ) -> [(day: Date, entries: [AgentAuditEntry])] {
        let all = SelfTest.isRunning ? [] : load()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
        var buckets: [Date: [AgentAuditEntry]] = [:]
        for entry in all where entry.at >= cutoff {
            buckets[calendar.startOfDay(for: entry.at), default: []].append(entry)
        }
        return buckets.keys.sorted(by: >).map { day in
            (day, (buckets[day] ?? []).sorted { $0.at > $1.at })
        }
    }
}
