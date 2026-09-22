import Foundation
import Observation

/// A goal the person is working toward (G1).
///
/// A goal advances only two ways: the person says so in their own words ("done", "I did
/// it", "stop"), or the person confirms evidence the Agent found. The model never moves
/// a goal on its own — a nudge is an ordinary `.reminder` schedule pointing at the goal
/// id, and the scheduler owns the timing while this store owns the meaning.
///
/// Consumer words everywhere: Goals, Reminders. Never cron, artifact, or tool ids.
struct AgentGoal: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable, CaseIterable {
        /// Working on it; nudges fire.
        case active
        /// No progress lately; nudges pause until the person answers.
        case stuck
        /// The person said it is done (or stopped). Nudges stop; `endsAt` enforced.
        case done
    }

    let id: UUID
    /// "Run twice a week" — the outcome the person restated yes to.
    var outcome: String
    /// "Lay out shoes tonight" — the first step, shown on the first nudge.
    var firstStep: String
    /// The sentence the person confirmed, rendered by code.
    var plainEnglish: String
    var state: State
    /// The reminder schedule carrying the nudges, if any.
    var nudgeScheduleID: UUID?
    /// Enforced by `GoalStore` on every pass: past it, the goal is done and nudges stop.
    var endsAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// The session that created it, for the audit trail.
    var createdInSession: UUID?

    init(
        id: UUID = UUID(),
        outcome: String,
        firstStep: String,
        plainEnglish: String,
        state: State = .active,
        nudgeScheduleID: UUID? = nil,
        endsAt: Date? = nil,
        createdAt: Date,
        createdInSession: UUID? = nil
    ) {
        self.id = id
        self.outcome = outcome
        self.firstStep = firstStep
        self.plainEnglish = plainEnglish
        self.state = state
        self.nudgeScheduleID = nudgeScheduleID
        self.endsAt = endsAt
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.createdInSession = createdInSession
    }

    /// The one-sentence restatement the Agent reads back before saving (G1 create flow).
    /// Includes the outcome and the first step, so "yes" means both.
    var restatement: String {
        "So your goal is \(outcome) — first step: \(firstStep). I’ll remind you so it stays easy. OK?"
    }

    /// What the nudge says. Consumer words; the goal id travels in the schedule prompt,
    /// never on screen.
    func nudgeText() -> String {
        "\(outcome) — \(firstStep)"
    }
}

/// `agent-goals.json`, written atomically like the schedules. The scheduler is never
/// written by a model; this store is written only through the create flow below (restate
/// → yes → save enabled) or by the person's own words in a conversation.
@MainActor
@Observable
final class GoalStore {
    static let shared: GoalStore = {
        if SelfTest.isRunning {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-goals-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            return GoalStore(directory: directory)
        }
        return GoalStore(directory: AppIdentity.applicationSupportDirectory)
    }()

    static let fileName = "agent-goals.json"

    private(set) var goals: [AgentGoal] = []
    private(set) var revision = 0

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
        goals = load()
    }

    func goal(id: UUID) -> AgentGoal? { goals.first { $0.id == id } }

    var activeGoals: [AgentGoal] { goals.filter { $0.state == .active } }

    // MARK: - Create flow (restate outcome + first step → yes → save enabled)

    /// The sentence the Agent reads back. Nothing is saved yet.
    static func restatement(outcome: String, firstStep: String, now: Date = Date()) -> String {
        AgentGoal(outcome: outcome, firstStep: firstStep, plainEnglish: "", createdAt: now).restatement
    }

    /// The person said yes. Saves the goal enabled with its first nudge visible: an
    /// ordinary `.reminder` schedule whose prompt points at the goal id, due at `firstNudge`.
    @discardableResult
    func confirm(outcome: String, firstStep: String, firstNudge: Date, endsAt: Date? = nil,
                 sessionID: UUID? = nil, now: Date = Date(),
                 schedules: ScheduleStore = .shared) -> AgentGoal {
        let plain = "Goal: \(outcome). First step: \(firstStep)."
        var goal = AgentGoal(outcome: outcome, firstStep: firstStep, plainEnglish: plain,
                             endsAt: endsAt, createdAt: now, createdInSession: sessionID)
        // The nudge is an ordinary reminder; the goal id rides in the prompt so the
        // scheduler never needs a new field (Schedules/* stays untouched).
        let when = GoalStore.nudgeWhen(for: firstNudge)
        var schedule = AgentSchedule(
            kind: .reminder, title: "Goal nudge: \(outcome)",
            plainEnglish: "I’ll remind you: \(goal.nudgeText()).",
            prompt: "Goal nudge for goal \(goal.id.uuidString): \(goal.nudgeText()).",
            when: when, endsAt: endsAt, delivery: .notifyAndSpeak, createdAt: now,
            createdInSession: sessionID)
        schedule.nextRunAt = firstNudge
        if schedules.save(schedule) { goal.nudgeScheduleID = schedule.id }
        goal.updatedAt = now
        var next = goals
        next.append(goal)
        write(next)
        return goal
    }

    // MARK: - Advance only by person word or confirmed evidence

    /// The person's own words about this goal ("done", "I did it", "stop", "stuck").
    /// Anything else leaves the goal alone. Returns the new state, or nil when the words
    /// were not about the goal.
    @discardableResult
    func advance(id: UUID, userWords: String, now: Date = Date(),
                 schedules: ScheduleStore = .shared) -> AgentGoal.State? {
        guard var goal = goal(id: id) else { return nil }
        let folded = userWords.lowercased()
        let doneCues = ["done", "did it", "finished", "completed", "stop", "no more", "cancel"]
        let stuckCues = ["stuck", "blocked", "can't", "cannot", "too hard", "gave up"]
        let resumeCues = ["resume", "restart", "keep going", "again"]
        let newState: AgentGoal.State?
        if doneCues.contains(where: folded.contains) { newState = .done }
        else if stuckCues.contains(where: folded.contains) { newState = .stuck }
        else if resumeCues.contains(where: folded.contains), goal.state == .stuck { newState = .active }
        else { return nil }
        goal.state = newState!
        goal.updatedAt = now
        save(goal)
        if newState == .done { stopNudges(for: goal, schedules: schedules, now: now) }
        return newState
    }

    /// Evidence the Agent found, confirmed by the person. The confirmation — not the
    /// finding — moves the goal.
    @discardableResult
    func confirmEvidence(id: UUID, confirmed: Bool, now: Date = Date(),
                         schedules: ScheduleStore = .shared) -> AgentGoal.State? {
        guard confirmed, let goal = goal(id: id), goal.state != .done else { return nil }
        return advance(id: id, userWords: "done", now: now, schedules: schedules)
    }

    /// `endsAt` enforcement: past it, the goal is done and its nudges stop. Called on
    /// every scheduler pass (via the self-test) and on launch.
    func enforceEndDates(now: Date = Date(), schedules: ScheduleStore = .shared) {
        for goal in goals where goal.state != .done {
            if let ends = goal.endsAt, ends <= now {
                var done = goal
                done.state = .done
                done.updatedAt = now
                save(done)
                stopNudges(for: done, schedules: schedules, now: now)
            }
        }
    }

    private func stopNudges(for goal: AgentGoal, schedules: ScheduleStore, now: Date) {
        guard let scheduleID = goal.nudgeScheduleID,
              var schedule = schedules.schedule(id: scheduleID) else { return }
        schedule.enabled = false
        schedule.nextRunAt = nil
        schedule.pendingDelivery = nil
        _ = schedules.save(schedule)
    }

    // MARK: - Store

    func save(_ goal: AgentGoal) {
        var next = goals
        if let index = next.firstIndex(where: { $0.id == goal.id }) { next[index] = goal }
        else { next.append(goal) }
        write(next)
    }

    func reload() { goals = load() }

    private func load() -> [AgentGoal] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try Self.decoder.decode([AgentGoal].self, from: data)
        } catch {
            Log.app.error("agent-goals.json is unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func write(_ next: [AgentGoal]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(next)
            try data.write(to: fileURL, options: .atomic)
            goals = next
            revision += 1
        } catch {
            Log.app.error("couldn't save agent-goals.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A one-shot reminder slot for the first nudge, in the current zone.
    static func nudgeWhen(for date: Date, zone: TimeZone = .current) -> ScheduleWhen {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        // The slot itself is the one-shot instant; the wall-clock fields feed the sentence.
        return ScheduleWhen(repeatRule: .once(date),
                            time: ScheduleLocalTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0),
                            timeZone: zone.identifier)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
