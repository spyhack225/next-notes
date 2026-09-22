import Foundation
import Observation

/// The `.extracting` stage: runs `KnowledgeExtractor` for a meeting whose notes were just
/// written, with the on-device model.
///
/// - **Off by default.** Only while the index and `knowledgeGraphEnabled` are both on.
/// - **Local only.** The on-device model under the grammar when it is downloaded, Apple's on-device model
///   (validated, not constrained) otherwise. The graph is the distilled version of every
///   meeting and is never sent to a cloud provider; with neither local model there is no
///   extraction, and the meeting simply reaches done.
/// - **Yields.** The model call goes through `NotesModelRuntime`'s background lane, which a
///   voice turn or live transcription takes first.
@MainActor
@Observable
final class KnowledgeExtractionService {
    static let shared = KnowledgeExtractionService()

    private(set) var running: Set<UUID> = []
    /// The last failure per meeting.
    private(set) var problems: [UUID: String] = [:]
    /// Bumped when a meeting's graph changes, so the decision thread re-reads.
    private(set) var revision = 0

    private let indexer: KnowledgeIndexer

    init(indexer: KnowledgeIndexer = .shared) {
        self.indexer = indexer
    }

    var isEnabled: Bool { indexer.settings.graphEnabled }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Extracts one meeting. Nil when the graph is off or no local model is available.
    @discardableResult
    func extract(
        _ meeting: Meeting, directory: URL, model: (any KnowledgeExtractionModel)? = nil, force: Bool = false
    ) async -> KnowledgeExtractionReport? {
        guard isEnabled else { return nil }
        // Already extracting (a backfill reached it while its notes were regenerated): wait,
        // then extract again — the earlier pass read the notes before they changed, and a
        // non-forced extraction of current notes costs a file read.
        while running.contains(meeting.id) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return nil }
        }
        guard isEnabled else { return nil }
        running.insert(meeting.id)
        defer { running.remove(meeting.id) }
        let chosen: (any KnowledgeExtractionModel)?
        if let model {
            chosen = model
        } else {
            chosen = await Self.localModel()
        }
        guard let chosen else {
            problems[meeting.id] = "No on-device model is available to extract decisions and action items."
            return nil
        }
        problems[meeting.id] = nil
        let extractor = KnowledgeExtractor(store: indexer.store)
        do {
            // Switched off while the model worked: `settingsMayHaveChanged` already deleted the
            // graph, and this write must not put it back.
            let report = try await extractor.extract(
                meetingDirectory: directory, model: chosen, force: force,
                isStillWanted: { await MainActor.run { self.isEnabled } })
            if !isEnabled {
                try? extractor.graph.deleteMeeting(meeting.id.uuidString)
                return nil
            }
            // Deleted while the model was working: `MeetingStore.delete` already removed the
            // graph, and this write must not put it back.
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingStore.recordFile).path) {
                try? extractor.graph.deleteMeeting(meeting.id.uuidString)
            }
            revision += 1
            // The people in it may be someone already known (Phase D).
            PersonResolutionService.shared.scheduleResolve()
            Log.llm.info("""
                extracted "\(meeting.title, privacy: .public)" — \(report.nodes, privacy: .public) nodes, \
                \(report.edges, privacy: .public) edges, \(report.violations.count, privacy: .public) dropped
                """)
            return report
        } catch is CancellationError {
            return nil
        } catch {
            problems[meeting.id] = error.localizedDescription
            Log.llm.error("extraction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Past meetings

    /// Meetings extracted so far in a running backfill, and how many it will visit.
    private(set) var backfillProgress: (done: Int, total: Int)?
    @ObservationIgnored private var backfillTask: Task<Void, Never>?

    var isBackfilling: Bool { backfillTask != nil }

    /// *Extract library*: every finished meeting with notes, then indexed dictations and
    /// Agent conversations (when those index toggles are on), oldest first. User-initiated
    /// only — minutes of model time. Meetings / sources whose extraction file is current cost
    /// a file read and no model call; the loop waits while anything records, transcribes,
    /// writes notes, or the Agent is replying or in a voice conversation.
    func extractLibrary(store: MeetingStore = .shared) {
        guard isEnabled, backfillTask == nil else { return }
        let meetings = store.meetings.filter { $0.status == .done && store.notes(for: $0.id) != nil }
            .sorted { $0.start < $1.start }
        let settings = indexer.settings
        let lifeSources: [(KnowledgeSourceKind, String)] = {
            var rows: [(KnowledgeSourceKind, String)] = []
            if settings.includeConversations {
                rows += ((try? indexer.store.indexedSources(kind: .conversation)) ?? [:]).keys
                    .sorted().map { (.conversation, $0) }
            }
            if settings.includeDictation {
                rows += ((try? indexer.store.indexedSources(kind: .dictation)) ?? [:]).keys
                    .sorted().map { (.dictation, $0) }
            }
            return rows
        }()
        let total = meetings.count + lifeSources.count
        backfillProgress = (0, total)
        backfillTask = Task { @MainActor [weak self] in
            defer {
                self?.backfillTask = nil
                self?.backfillProgress = nil
            }
            var done = 0
            for meeting in meetings {
                while LiveKnowledgeIndexEnvironment.isForegroundBusy || LiveKnowledgeIndexEnvironment.isVoiceBusy,
                      !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                }
                guard let self, !Task.isCancelled, self.isEnabled else { return }
                guard let current = store.meeting(id: meeting.id), current.status == .done else { continue }
                await self.extract(current, directory: store.directory(for: current.id))
                done += 1
                self.backfillProgress = (done, total)
            }
            for (kind, sourceID) in lifeSources {
                while LiveKnowledgeIndexEnvironment.isForegroundBusy || LiveKnowledgeIndexEnvironment.isVoiceBusy,
                      !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                }
                guard let self, !Task.isCancelled, self.isEnabled else { return }
                await self.extractLife(kind: kind, sourceID: sourceID)
                done += 1
                self.backfillProgress = (done, total)
            }
        }
    }

    /// One dictation or conversation into the life map.
    @discardableResult
    func extractLife(
        kind: KnowledgeSourceKind, sourceID: String, model: (any KnowledgeExtractionModel)? = nil, force: Bool = false
    ) async -> KnowledgeExtractionReport? {
        guard isEnabled, kind == .dictation || kind == .conversation else { return nil }
        let chosen: (any KnowledgeExtractionModel)?
        if let model {
            chosen = model
        } else {
            chosen = await Self.localModel()
        }
        guard let chosen else { return nil }
        let extractor = LifeSourceExtractor(store: indexer.store)
        do {
            let report = try await extractor.extract(
                kind: kind, sourceID: sourceID, model: chosen, force: force,
                isStillWanted: { await MainActor.run { self.isEnabled } })
            if !isEnabled {
                try? extractor.graph.deleteMeeting(GraphIDs.lifeSource(kind: kind, id: sourceID))
                return nil
            }
            revision += 1
            PersonResolutionService.shared.scheduleResolve()
            Log.llm.info("""
                life-extracted \(kind.rawValue, privacy: .public) \(sourceID, privacy: .public) — \
                \(report.nodes, privacy: .public) nodes, \(report.edges, privacy: .public) edges
                """)
            return report
        } catch is CancellationError {
            return nil
        } catch {
            Log.llm.error("life extraction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func cancelBackfill() {
        backfillTask?.cancel()
        backfillTask = nil
        backfillProgress = nil
    }

    /// The on-device model (grammar-constrained) or Apple's on-device model. Never OpenRouter.
    static func localModel() async -> (any KnowledgeExtractionModel)? {
        guard let provider = await LLMProviders.resolve(preferring: .gemma4E4B), provider.id != .openRouter else {
            return nil
        }
        return ProviderExtractionModel(provider: provider)
    }
}

// MARK: - Reminder suggestions

/// An action item the user owns, with a due date that has not passed, offered as a reminder.
///
/// Offered, never created: *Remind me* calls `schedule.create` with these fields, which shows
/// its confirmation card. The text is model output from other people's words, so it goes in
/// as a reminder's title and text — never as a prompt a planner would read.
struct ActionItemReminderSuggestion: Identifiable, Equatable, Sendable {
    /// The action item and its due date: a new date is a new suggestion.
    var id: String
    var itemID: String
    var text: String
    /// `YYYY-MM-DD`.
    var due: String
    var meetingID: String
    var meetingTitle: String
    var sourceChunk: Int64

    /// `schedule.create`'s arguments: a one-off reminder at 9:00 on the due date.
    var reminderArguments: [String: String] {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["kind": "reminder", "title": String(task.prefix(60)), "text": task,
                "repeat": "once", "date": due, "time": "09:00"]
    }
}

enum ActionItemReminders {
    /// What an owner is called when it is the user: the mic track's label and the pronouns a
    /// model writes for it.
    static let selfNames: Set<String> = ["you", "me", "i", "myself"]

    /// The user's own names on this Mac, first name and full.
    static var localUserNames: Set<String> {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        guard !full.isEmpty else { return [] }
        var names: Set<String> = [full.lowercased()]
        if let first = full.split(separator: " ").first { names.insert(first.lowercased()) }
        return names
    }

    static func isUser(_ owner: String?, names: Set<String>) -> Bool {
        guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !owner.isEmpty else {
            return false
        }
        return selfNames.contains(owner) || names.contains(owner)
    }

    static func suggestions(
        items: [GraphActionItem], userNames: Set<String>, resolved: Set<String>, now: Date,
        calendar: Calendar = .current
    ) -> [ActionItemReminderSuggestion] {
        let today = calendar.startOfDay(for: now)
        return items.compactMap { item in
            guard isUser(item.owner, names: userNames), let due = item.due,
                  let components = Ontology.day(due, calendar: calendar),
                  let day = calendar.date(from: components), day >= today else { return nil }
            let id = "\(item.id)@\(due)"
            guard !resolved.contains(id) else { return nil }
            return ActionItemReminderSuggestion(id: id, itemID: item.id, text: item.text, due: due,
                                                meetingID: item.meetingID, meetingTitle: item.meetingTitle,
                                                sourceChunk: item.sourceChunk)
        }
        .sorted { $0.due != $1.due ? $0.due < $1.due : $0.id < $1.id }
    }
}

/// `knowledge-reminder-suggestions.json`: the suggestions the user has answered, so each is
/// offered once. Written atomically.
@MainActor
@Observable
final class ReminderSuggestionStore {
    /// A self-test never touches the user's file.
    static let shared: ReminderSuggestionStore = {
        if SelfTest.isRunning {
            return ReminderSuggestionStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-reminders-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true))
        }
        return ReminderSuggestionStore(directory: AppIdentity.applicationSupportDirectory)
    }()

    static let fileName = "knowledge-reminder-suggestions.json"

    private(set) var resolved: Set<String> = []
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            resolved = Set(stored)
        }
    }

    /// *Remind me* or *Dismiss*: either way it is not offered again.
    func resolve(_ id: String) {
        guard resolved.insert(id).inserted else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(resolved.sorted()).write(to: fileURL, options: .atomic)
        } catch {
            Log.agent.error("reminder suggestions not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
