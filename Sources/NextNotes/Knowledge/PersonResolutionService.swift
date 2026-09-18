import Foundation
import Observation

/// What `NextMemory` gets from resolution.
enum MemoryPeople: Equatable, Sendable {
    /// No graph: person items the graph made earlier go.
    case graphOff
    /// The graph is on but nothing is loaded yet: memory keeps what it has.
    case notLoaded
    /// One person item per resolved person.
    case resolved([ResolvedPerson])
}

/// What one resolution run did.
struct PersonResolutionReport: Equatable, Sendable {
    var mentions = 0
    var people = 0
    var merged = 0
    var candidates = 0
    var compared = 0
    var possible = 0
    var modelCalls = 0
}

/// Runs entity resolution (Part 4, Phase D) and applies what the user decides in
/// `MergePeopleSheet`.
///
/// - **Off by default.** Only while `knowledgeGraphEnabled` (and the index) is on: people are
///   resolved from the graph, and there is no graph otherwise.
/// - **After extraction.** A meeting's graph changing, or a new `speakers.json`, schedules a
///   run. Scoring is milliseconds of SQL and arithmetic; the model tiebreak is on-device only
///   (Qwen or Apple's model, never OpenRouter), capped per run, and skipped while anything
///   records or the Agent is busy — the pairs wait in the review sheet instead.
/// - **Never destructive.** A merge sets `merged_into`; *Split* is one row's update, and the
///   user's word is kept in `knowledge-person-decisions.json` so a rebuilt index agrees.
@MainActor
@Observable
final class PersonResolutionService {
    /// A self-test never touches the user's decisions file.
    static let shared: PersonResolutionService = {
        if SelfTest.isRunning {
            return PersonResolutionService(
                indexer: .shared,
                decisions: PersonDecisionLog(directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NextNotesSelfTest-people-\(ProcessInfo.processInfo.processIdentifier)",
                                            isDirectory: true)),
                tiebreaker: { nil })
        }
        return PersonResolutionService(
            indexer: .shared, decisions: PersonDecisionLog(directory: AppIdentity.applicationSupportDirectory),
            tiebreaker: {
                guard !LiveKnowledgeIndexEnvironment.isForegroundBusy, !LiveKnowledgeIndexEnvironment.isVoiceBusy,
                      let model = await KnowledgeExtractionService.localModel() else { return nil }
                // Checked again before every call: a recording or a conversation can start mid-run.
                return YieldingPersonTiebreaker(base: ModelPersonTiebreaker(model: model)) {
                    await MainActor.run {
                        LiveKnowledgeIndexEnvironment.isForegroundBusy || LiveKnowledgeIndexEnvironment.isVoiceBusy
                    }
                }
            })
    }()

    private(set) var people: [ResolvedPerson] = []
    private(set) var candidates: [PersonCandidate] = []
    private(set) var isResolving = false
    private(set) var problem: String?
    private(set) var lastReport: PersonResolutionReport?
    /// Bumped whenever who-is-who changes, so views and the memory re-read.
    private(set) var revision = 0
    /// Whether `people` reflects the store yet. Until it does, memory keeps its own
    /// attendee items rather than dropping them.
    private(set) var hasLoaded = false
    /// The last action in the sheet, for *Undo*.
    private(set) var lastAction: Action?

    enum Action: Equatable, Sendable {
        /// `restoredApart`: the "different people" the merge withdrew, put back by *Undo*.
        case merged(id: String, into: String, restoredApart: PersonPair? = nil)
        case split(id: String, from: String)
        case keptApart(PersonPair)
    }

    let decisions: PersonDecisionLog
    let resolver: EntityResolver
    private let indexer: KnowledgeIndexer
    private let tiebreaker: @MainActor () async -> (any PersonTiebreaker)?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var rerun = false

    init(indexer: KnowledgeIndexer, decisions: PersonDecisionLog, resolver: EntityResolver = EntityResolver(),
         tiebreaker: @escaping @MainActor () async -> (any PersonTiebreaker)?) {
        self.indexer = indexer
        self.decisions = decisions
        self.resolver = resolver
        self.tiebreaker = tiebreaker
    }

    var isEnabled: Bool { indexer.settings.graphEnabled }

    private var store: PersonResolutionStore { PersonResolutionStore(store: indexer.store) }

    // MARK: - Running

    /// A run a few seconds from now; several changes in a row are one run.
    func scheduleResolve() {
        guard isEnabled else { return }
        scheduled?.cancel()
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            await self.resolve()
        }
    }

    @discardableResult
    func resolve(tiebreaker explicit: (any PersonTiebreaker)? = nil, useModel: Bool = true) async -> PersonResolutionReport? {
        guard isEnabled, indexer.store.existsOnDisk else { return nil }
        guard !isResolving else {
            rerun = true
            return nil
        }
        isResolving = true
        defer {
            isResolving = false
            if rerun {
                rerun = false
                scheduleResolve()
            }
        }
        let chosen: (any PersonTiebreaker)?
        if let explicit {
            chosen = explicit
        } else {
            chosen = useModel ? await tiebreaker() : nil
        }
        let storeHandle = indexer.store
        let root = indexer.meetingsRoot
        let decided = decisions.decisions
        let resolver = self.resolver
        let generation = storeHandle.mutationCount
        let result = await Task.detached(priority: .utility) { () -> Result<(ResolutionPlan, [PersonMention]), Error> in
            do {
                let mentions = try PersonEvidenceLoader(store: storeHandle, meetingsRoot: root).load()
                let resolutions = PersonResolutionStore(store: storeHandle)
                let plan = await resolver.resolve(mentions, decisions: decided, verdicts: (try? resolutions.verdicts()) ?? [:],
                                                  tiebreaker: chosen)
                return .success((plan, mentions))
            } catch {
                return .failure(error)
            }
        }.value
        // Switched off while it ran: the graph (and these rows) are already gone.
        guard isEnabled, !Task.isCancelled, storeHandle.existsOnDisk else { return nil }
        guard decisions.decisions == decided, storeHandle.mutationCount == generation else {
            rerun = true
            return nil
        }
        switch result {
        case .success(let (plan, mentions)):
            do {
                try store.apply(plan, mentions: mentions)
            } catch {
                problem = error.localizedDescription
                return nil
            }
            let merged = plan.assignments.values.filter { $0.mergedInto != nil }.count
            let report = PersonResolutionReport(
                mentions: mentions.count, people: mentions.count - merged, merged: merged,
                candidates: plan.candidates.filter { $0.verdict == nil }.count, compared: plan.compared,
                possible: plan.possible, modelCalls: plan.asked.count)
            problem = nil
            lastReport = report
            reload()
            Log.llm.info("""
                resolved people — \(report.mentions, privacy: .public) mentions, \(report.merged, privacy: .public) merged, \
                \(report.compared, privacy: .public)/\(report.possible, privacy: .public) pairs compared, \
                \(report.modelCalls, privacy: .public) model calls
                """)
            return report
        case .failure(let error):
            problem = error.localizedDescription
            Log.llm.error("person resolution failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Re-reads the store without resolving.
    func reload() {
        guard isEnabled, indexer.store.existsOnDisk else {
            people = []
            candidates = []
            hasLoaded = false
            revision += 1
            return
        }
        do {
            people = try store.people()
            var root: [String: String] = [:]
            for person in people {
                root[person.id] = person.id
                for member in person.members { root[member.id] = person.id }
            }
            // Unanswered pairs, and pairs the model called the same but the score was too weak
            // to merge on its word alone; never a pair already merged or answered "different".
            candidates = try store.candidates().filter { candidate in
                candidate.verdict != false
                    && (root[candidate.pair.a] ?? candidate.pair.a) != (root[candidate.pair.b] ?? candidate.pair.b)
            }
            hasLoaded = true
        } catch {
            problem = error.localizedDescription
        }
        revision += 1
    }

    // MARK: - The review sheet

    /// "These are the same person." One row updated; the decision kept for rebuilds.
    func merge(_ id: String, into target: String) {
        do {
            let canonicalTarget = try store.canonical(target)
            let canonicalID = try store.canonical(id)
            guard canonicalTarget != id, canonicalTarget != canonicalID else { return }
            // A "different people" the user gave someone already in either group would undo
            // this merge on the next run; say so rather than write a merge that will not hold.
            let apart = decisions.decisions.apart
            let groupA = memberIDs(of: canonicalID), groupB = memberIDs(of: canonicalTarget)
            let direct = PersonPair(id, canonicalTarget)
            if let blocking = apart.first(where: { pair in
                pair != direct && ((groupA.contains(pair.a) && groupB.contains(pair.b))
                    || (groupA.contains(pair.b) && groupB.contains(pair.a)))
            }) {
                let names = displayNames
                problem = "You kept \(names[blocking.a] ?? blocking.a) and \(names[blocking.b] ?? blocking.b) apart. "
                    + "Split them out first, or undo that."
                return
            }
            // The store first: a decision is kept only for a merge the store could make.
            guard try store.merge(id, into: canonicalTarget) > 0 else {
                problem = "That person is no longer in the library. Resolve again and retry."
                return
            }
            let withdrawn = apart.contains(direct) ? direct : nil
            try decisions.recordMerge(id, into: canonicalTarget)
            problem = nil
            lastAction = .merged(id: id, into: canonicalTarget, restoredApart: withdrawn)
            reload()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Everyone resolved as the same person as `id`, from the loaded people.
    private func memberIDs(of id: String) -> Set<String> {
        guard let person = people.first(where: { $0.id == id || $0.members.contains { $0.id == id } }) else { return [id] }
        return Set([person.id] + person.members.map(\.id))
    }

    /// Mention id → the name the sheet shows.
    var displayNames: [String: String] {
        var result: [String: String] = [:]
        for person in people {
            result[person.id] = person.name
            for member in person.members { result[member.id] = member.label }
        }
        return result
    }

    /// "Not the same person." One row updated; they are never merged again automatically.
    func split(_ id: String) {
        do {
            guard let result = try store.split(id) else { return }
            try decisions.recordApart(id, from: result.previous)
            lastAction = .split(id: id, from: result.previous)
            reload()
            // Anyone else who had joined through it may belong elsewhere now.
            scheduleResolve()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A suggestion answered "different people".
    func keepApart(_ pair: PersonPair) {
        do {
            try decisions.recordApart(pair.a, from: pair.b)
            lastAction = .keptApart(pair)
            candidates.removeAll { $0.pair == pair }
            revision += 1
        } catch {
            problem = error.localizedDescription
        }
    }

    func undo() {
        guard let action = lastAction else { return }
        lastAction = nil
        do {
            switch action {
            case .merged(let id, _, let restoredApart):
                try decisions.withdrawMerge(id)
                if let restoredApart { try decisions.recordApart(restoredApart.a, from: restoredApart.b) }
                _ = try store.split(id)
                reload()
                scheduleResolve()
            case .split(let id, let from):
                try decisions.recordMerge(id, into: from)
                try store.merge(id, into: from)
                reload()
            case .keptApart(let pair):
                try decisions.withdrawApart(pair.a, from: pair.b)
                scheduleResolve()
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Memory

    /// What `NextMemory` keeps as person items: one per resolved person, with the names they
    /// were also mentioned as. Loads the store the first time after launch, so a relaunch does
    /// not wait for the next extraction. `.graphOff` makes memory drop what the graph gave it.
    func memoryPeople() -> MemoryPeople {
        guard isEnabled, indexer.store.existsOnDisk else { return isEnabled ? .notLoaded : .graphOff }
        if !hasLoaded { reload() }
        guard hasLoaded else { return .notLoaded }
        return .resolved(people.filter { $0.kind == .person })
    }
}
