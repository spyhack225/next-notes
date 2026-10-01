import Foundation
import Observation

/// The tool executor binds the run and exact step before entering a backing. The binding
/// survives async browser work; a late capture cannot attach itself to a newer step.
/// It carries identity only, never another ledger or execution owner.
enum AgentWorkPresentationScope {
    struct Binding: Sendable, Equatable {
        let taskID: String
        let stepID: String
    }
    @TaskLocal static var binding: Binding?
}

/// Memory-only context reported by the actual computer backing. Only the newest step
/// keeps it, so a history row neither retains window pixels nor looks live after finish.
struct AgentWorkPreview: Sendable, Equatable {
    var summary: String
    var thumbnail: Data? = nil
    var isYielded = false
}

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
    var preview: AgentWorkPreview? = nil

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
        if !steps.isEmpty {
            steps[steps.count - 1].isCompleted = true
            steps[steps.count - 1].preview = nil
        }
        let state = avatar ?? AgentAvatarState(activity: kind)
        steps.append(AgentStep(title: title, detail: detail, avatar: state))
        taskSteps[taskID] = steps
        liveAvatarState = state
    }

    func finish(taskID: String, title: String) {
        append(AgentActivity(taskID: taskID, kind: .completed, title: title))
        if var steps = taskSteps[taskID], !steps.isEmpty {
            steps[steps.count - 1].isCompleted = true
            steps[steps.count - 1].preview = nil
            taskSteps[taskID] = steps
        }
        if activeTaskID == taskID { activeTaskID = nil }
        liveAvatarState = nil
    }

    /// Only explicitly bound tasks with a live step can receive window context. Never
    /// fall back to activeTaskID: a second run may have become active during capture.
    func presentationBinding(taskID: String?) -> AgentWorkPresentationScope.Binding? {
        guard let taskID, !taskID.isEmpty,
              let step = taskSteps[taskID]?.last, !step.isCompleted else { return nil }
        return .init(taskID: taskID, stepID: step.id)
    }

    func noteWindow(
        _ summary: String, thumbnail: Data? = nil,
        binding: AgentWorkPresentationScope.Binding? = AgentWorkPresentationScope.binding
    ) {
        guard let binding, var steps = taskSteps[binding.taskID],
              let last = steps.last, last.id == binding.stepID, !last.isCompleted else { return }
        // A later inspection replaces a previous image: the tree is the current context,
        // and the old screenshot is not evidence about this new observation.
        steps[steps.count - 1].preview = .init(summary: summary, thumbnail: thumbnail)
        taskSteps[binding.taskID] = steps
    }

    func noteHumanYield(
        binding: AgentWorkPresentationScope.Binding? = AgentWorkPresentationScope.binding
    ) {
        guard let binding, var steps = taskSteps[binding.taskID],
              let last = steps.last, last.id == binding.stepID, !last.isCompleted else { return }
        var preview = last.preview ?? .init(summary: "Paused while you’re using your Mac.")
        preview.isYielded = true
        // The person is changing the window; its last image is no longer live context.
        preview.thumbnail = nil
        steps[steps.count - 1].preview = preview
        taskSteps[binding.taskID] = steps
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

    /// P1-29: how many rows the **in-memory** list keeps. Named because the file it was
    /// written next to was an unnamed `400`, and a number with no name is a number nobody can
    /// change on purpose. The file is a different budget and a different rule — see
    /// `rotateIfNeeded`.
    static let memoryRows = 400

    /// `nonisolated` with `load()`, and for the same reason: it derives a path and touches no
    /// main-actor state. The rotated file's URL is built the same way beside it, so the two
    /// cannot drift onto different directories.
    nonisolated private static var fileURL: URL {
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
        triggerQuote: String? = nil,
        turnID: UUID? = nil,
        conversationID: UUID? = nil
    ) {
        // Self-tests may inspect the in-memory audit trail (see `--selftest-tasks`),
        // but must never write fixture text into the person's persistent history —
        // the same split ActionReceiptStore uses.
        // P1-29: the turn and conversation are filled **here**, not at each call site.
        //
        // The task's promise is that a single request can be followed from its audit row to its
        // model passes by `turnID` alone, and the only way that is true by construction rather
        // than by remembering is for the one writer to stamp every row. A caller that knows a
        // different turn — a routine, a recovery, an idle unload with no turn at all — passes
        // its own; nil here means "whatever turn is running", which is the right default for
        // every request, reply, tool, permission and wake row.
        let entry = AgentAuditEntry(
            kind: kind,
            title: title,
            detail: detail,
            toolID: toolID,
            taskID: taskID,
            meetingID: meetingID,
            scheduleID: scheduleID,
            triggerQuote: triggerQuote,
            turnID: turnID ?? RealtimeAgent.shared.currentTurnID,
            conversationID: conversationID ?? AgentSession.shared.sessionID
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.memoryRows { entries = Array(entries.prefix(Self.memoryRows)) }
        guard !SelfTest.isRunning else { return }
        appendToDisk(entry)
    }

    /// P1-29: rotate at 8 MB, the same rule and the same size `UsageLog` uses.
    ///
    /// The audit file was **append-only and never trimmed** — only the in-memory list was
    /// capped — so it grew without bound and a person's activity history was a file that could
    /// fill a disk. One rotation, one file kept: `agent-audit.1.jsonl` beside it, exactly the
    /// shape `usage.1.jsonl` has, so the reader is the same two-file walk.
    ///
    /// Rotation happens **before** the append that would pass the limit, so the line that tips
    /// it over lands in the new file rather than in one that is already too big.
    private func rotateIfNeeded(adding bytes: Int) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: Self.fileURL.path),
              let size = attributes[.size] as? Int, size + bytes > Self.maxFileBytes else { return }
        let rotated = Self.rotatedFileURL
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: Self.fileURL, to: rotated)
    }

    static let maxFileBytes = 8 * 1_024 * 1_024
    nonisolated static var rotatedFileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent(rotatedFileName)
    }
    nonisolated static let rotatedFileName = "agent-audit.1.jsonl"

    private func appendToDisk(_ entry: AgentAuditEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        rotateIfNeeded(adding: line.utf8.count)
        if FileManager.default.fileExists(atPath: Self.fileURL.path),
           let handle = try? FileHandle(forWritingTo: Self.fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: Self.fileURL, options: .atomic)
        }
    }

    /// P1-29: the whole audit file, for a report that runs outside the harness.
    ///
    /// `entries` is the wrong reader here for two reasons: it holds at most `memoryRows` of
    /// whatever this launch has written, and under `SelfTest.isRunning` it starts empty on
    /// purpose. `--usage-report --usage-turn <id>` needs every row on disk, and it must be
    /// callable off the main actor, so the load is `static` and returns a value.
    nonisolated static func loadForReport() -> [AgentAuditEntry] { load() }

    /// `nonisolated` because it reads a file and builds a value: no `self`, no main-actor
    /// state, and `--usage-report` calls it off the main actor. The enclosing class being
    /// `@MainActor` does not make a stateless static actor-bound, and marking this one so
    /// would have forced the report to hop for no reason.
    nonisolated private static func load() -> [AgentAuditEntry] {
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
