import Foundation

enum AgentTaskPersistenceResult: Equatable {
    case saved, jsonFailed, mirrorFailed, loadFailed, sqlFailed, exportFailed, endedTask, invalidCompletion, invalidTransition

    var primaryCommitted: Bool { self == .saved || self == .exportFailed || self == .mirrorFailed }

    var diagnostic: String? {
        switch self {
        case .saved: nil
        case .endedTask: "This task has already ended. Its saved result was kept."
        case .invalidTransition: "This task cannot change to that state. Its saved state was kept."
        case .invalidCompletion: "This result isn't finished. The task's saved state was kept."
        case .jsonFailed: "Task history could not be saved. The durable copy was not changed."
        case .mirrorFailed: "Task history was saved, but its durable copy could not be updated."
        case .sqlFailed: "Task history could not be saved. Your saved history was kept."
        case .exportFailed: "Task history was saved, but its additional local copy could not be updated."
        case .loadFailed: "Task history could not be read. Your saved history was kept, and new work has not started."
        }
    }
}

/// SQLite becomes authority only after strict reconciliation and a transactional marker.
/// The retained tagged JSON is a compatibility export for this decoder, not an older binary.
private struct TaskHistoryExport: Codable {
    let formatVersion: Int
    let preparedAuthority: TaskStoreAuthority
    let fileIdentity: TaskStoreFileIdentity
    let tasks: [AgentTask]
}

private struct TaskHistoryExportHeader: Decodable {
    let formatVersion: Int
    let preparedAuthority: TaskStoreAuthority
    let fileIdentity: TaskStoreFileIdentity
}

@MainActor
final class AgentTaskStore {
    static let shared = AgentTaskStore()

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("agent-tasks.json")
    }

    /// A fixture supplies its exact file before seeding. Nil retains the shared store's
    /// existing path resolution; an injected URL never falls back to the owner's file.
    private let injectedFileURL: URL?
    private let injectedMirror: TaskStore?
    private lazy var mirror = injectedMirror ?? TaskStore(root: storageURL.deletingLastPathComponent())
    private var failedLoad = false
    private var expectedAuthority: TaskStoreAuthority?
    private var expectedIdentity: TaskStoreFileIdentity?

    /// Encoding fragments of our own successful export, not another task owner.
    /// Every activity still reads/checks the actual witness and commits/writes once.
    private struct ActivityExport {
        let authority: TaskStoreAuthority
        let identity: TaskStoreFileIdentity
        let bytes: Data
        let ids: [String]
        let rows: [Data]
    }
    private var activityExport: ActivityExport?

    private static func activityExport(_ bytes: Data, tasks: [AgentTask], authority: TaskStoreAuthority,
                                       identity: TaskStoreFileIdentity) -> ActivityExport? {
        // This scans ONLY bytes just encoded by our existing sorted-key encoder.
        // It is not an alternate decoder for external task payloads.
        let marker = Data("\"tasks\" : [".utf8)
        guard let found = bytes.range(of: marker) else { return nil }
        let data = [UInt8](bytes)
        var index = found.upperBound
        var rows: [Data] = []
        var rowStart: Int?
        var depth = 0
        var quoted = false
        var escaped = false
        while index < data.count {
            let byte = data[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                if depth == 0 { rowStart = index }
                depth += 1
            } else if byte == 125 || byte == 93 {
                if byte == 93 && depth == 0 {
                    guard rows.count == tasks.count else { return nil }
                    return ActivityExport(authority: authority, identity: identity, bytes: bytes,
                        ids: tasks.map(\.id), rows: rows)
                }
                depth -= 1
                guard depth >= 0 else { return nil }
                if depth == 0, let start = rowStart {
                    rows.append(Data(bytes[start...index])); rowStart = nil
                }
            }
            index += 1
        }
        return nil
    }

    private static func activityBytes(rows: [Data], authority: TaskStoreAuthority,
                                      identity: TaskStoreFileIdentity, reserving capacity: Int) throws -> Data {
        let empty = try encoder().encode(TaskHistoryExport(formatVersion: 1,
            preparedAuthority: authority, fileIdentity: identity, tasks: []))
        let marker = Data("\"tasks\" : [".utf8)
        guard let found = empty.range(of: marker), let end = empty[found.upperBound...].firstIndex(of: 93) else {
            throw TaskStoreError.invalidRecord
        }
        var bytes = Data(empty[..<found.upperBound])
        // The already-retained OWN export supplies capacity, never bytes or authority.
        // Appending still grows if the new header needs more; output stays identical.
        bytes.reserveCapacity(max(capacity, empty.count))
        for (index, row) in rows.enumerated() {
            if index > 0 { bytes.append(44) }
            bytes.append(row)
        }
        bytes.append(contentsOf: empty[end...])
        return bytes
    }

    /// Injected temporary fixtures may interrupt exact persistence boundaries. Production
    /// and the owner-path harness never call this observer; it carries no task payload.
    var migrationBoundaryForTesting: ((String) throws -> Void)?

    init(fileURL: URL? = nil, mirror: TaskStore? = nil) {
        injectedFileURL = fileURL
        injectedMirror = mirror
    }

    /// Read-only location lets an isolated fixture verify its binding before seeding.
    var storageURL: URL { injectedFileURL ?? Self.fileURL }

    /// Only explicitly injected temporary stores may drive the real persistence seam in
    /// a harness. Shared/default stores keep P0-11's no-write guard, including their mirror.
    var allowsHarnessPersistence: Bool {
        guard injectedFileURL != nil else { return false }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        return [storageURL, mirror.fileURL].allSatisfy {
            $0.resolvingSymlinksInPath().path.hasPrefix(root)
        }
    }

    /// The same stored task representation, without any store construction or I/O.
    /// A live voice proposal uses this before its first pending/card snapshot.
    static func canonicalPermissionRequest(_ request: PermissionRequest) throws -> PermissionRequest {
        try decoder().decode(PermissionRequest.self, from: encoder().encode(request))
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func compatibilityData() throws -> Data? {
        do { return try Data(contentsOf: storageURL) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private static func legacyTasks(_ data: Data?) throws -> [AgentTask] {
        guard let data else { return [] }
        let tasks = try decoder().decode([AgentTask].self, from: data)
        try TaskStore.validate(tasks)
        return tasks
    }

    private func boundary(_ name: String) throws {
        if SelfTest.isRunning, let observer = migrationBoundaryForTesting, allowsHarnessPersistence { try observer(name) }
    }

    private func check(_ probe: TaskStoreAuthorityProbe, witness: Data?, retainedExport: ActivityExport? = nil) throws {
        guard let authority = probe.authority else { throw TaskStoreError.authorityConflict }
        if let expectedAuthority {
            guard expectedAuthority == authority, expectedIdentity == probe.identity else {
                throw TaskStoreError.authorityConflict
            }
        }
        if let cached = activityExport ?? retainedExport, witness == cached.bytes,
           cached.authority == authority, cached.identity == probe.identity { return }
        // SQL is selected before compatibility payload decoding. A readable header can
        // detect known rollback/replacement; absent/corrupt exports supply no witness.
        if let witness, let header = try? Self.decoder().decode(TaskHistoryExportHeader.self, from: witness) {
            guard header.formatVersion == 1, header.preparedAuthority.databaseID == authority.databaseID,
                  header.preparedAuthority.generation > 0,
                  header.preparedAuthority.generation <= authority.generation,
                  header.fileIdentity.matchesPersistedWitness(probe.identity) else { throw TaskStoreError.authorityConflict }
        }
    }

    /// Existing-only canonical rows and journal, using the same identity/witness
    /// check as load. This does not create, repair or dispatch task history.
    func recoveredReadHistory() throws -> TaskStoreAuthorityProbe {
        guard !failedLoad, !SelfTest.isRunning || allowsHarnessPersistence,
              let probe = try mirror.probeAuthority(includeTasks: true, includeJournal: true),
              probe.authority != nil else { throw TaskStoreError.authorityConflict }
        try check(probe, witness: try? compatibilityData())
        return probe
    }

    func load() throws -> [AgentTask] {
        activityExport = nil
        do {
            // A denied harness store must neither read owner JSON nor open/migrate SQL.
            // Only explicitly injected safe temporary JSON AND SQL may expose history.
            if SelfTest.isRunning && !allowsHarnessPersistence {
                failedLoad = false
                return []
            }
            let probe = try mirror.probeAuthority()
            if let probe, probe.authority != nil {
                // Export corruption/unreadability does not override valid marked SQL.
                try check(probe, witness: try? compatibilityData())
                expectedAuthority = probe.authority
                expectedIdentity = probe.identity
                failedLoad = false
                return probe.tasks
            }
            guard expectedAuthority == nil else { throw TaskStoreError.authorityConflict }
            let data = try compatibilityData()
            if let data, (try? Self.decoder().decode(TaskHistoryExportHeader.self, from: data)) != nil {
                // Prepared plus unmarked is uncertain, even if a restored backup retains
                // the same identity. Ordinary loading never reconciles it automatically.
                throw TaskStoreError.authorityConflict
            }
            let tasks = try Self.legacyTasks(data)
            if let probe { try mirror.preflightImport(tasks, probe: probe) }
            let binding = try probe ?? mirror.createForImport()
            let authority = TaskStoreAuthority(databaseID: UUID(), generation: 1)
            let envelope = TaskHistoryExport(formatVersion: 1, preparedAuthority: authority,
                fileIdentity: binding.identity, tasks: tasks)
            try boundary("beforePreparation")
            try Self.encoder().encode(envelope).write(to: storageURL, options: .atomic)
            try boundary("prepared")
            try mirror.reconcile(tasks, probe: binding, authority: authority, freshlyCreated: probe == nil)
            try boundary("authorityCommitted")
            expectedAuthority = authority
            expectedIdentity = binding.identity
            failedLoad = false
            return tasks
        } catch {
            failedLoad = true
            throw error
        }
    }

    private func preparedHistory() throws -> (Data, TaskHistoryExport) {
        guard !SelfTest.isRunning || allowsHarnessPersistence,
              expectedAuthority == nil, let data = try compatibilityData() else {
            throw TaskStoreError.authorityConflict
        }
        let envelope = try Self.decoder().decode(TaskHistoryExport.self, from: data)
        try TaskStore.validate(envelope.tasks)
        guard envelope.formatVersion == 1, envelope.preparedAuthority.generation == 1,
              envelope.fileIdentity.inode > 0 else { throw TaskStoreError.authorityConflict }
        _ = try mirror.probePreparedImport(envelope.tasks, identity: envelope.fileIdentity)
        return (data, envelope)
    }

    /// A read-only affordance. A damaged, missing, marked, replaced or conflicting
    /// history never earns a repair button. The action revalidates instead of trusting it.
    var canRepairPreparedHistory: Bool { (try? preparedHistory()) != nil }

    /// Explicit user action repairs only a retained generation-one preparation into
    /// its exact existing ledger. It does not discard history or dispatch any task.
    func repairPreparedHistory() throws {
        activityExport = nil
        let (data, envelope) = try preparedHistory()
        try mirror.repairPreparedImport(envelope.tasks, identity: envelope.fileIdentity,
                                       authority: envelope.preparedAuthority) {
            guard try self.compatibilityData() == data else { throw TaskStoreError.authorityConflict }
        }
        expectedAuthority = envelope.preparedAuthority
        expectedIdentity = envelope.fileIdentity
        failedLoad = false
    }

    func reconcilePreparedForTesting() throws {
        guard SelfTest.isRunning, allowsHarnessPersistence else { throw TaskStoreError.authorityConflict }
        try repairPreparedHistory()
    }

    /// Preserve the Bool execution contract and the same authority-bound row read.
    func matchesWorker(_ worker: TaskWorkerWriteCondition) -> Bool {
        workerPrimaryObservation(worker).outcome == .accepted
    }

    /// Any failed source/binding/read boundary returns unknown metadata, never absence.
    func workerPrimaryObservation(_ worker: TaskWorkerWriteCondition) -> TaskWorkerPrimaryObservation {
        let unavailable = TaskWorkerPrimaryObservation(expected: worker, outcome: .unavailable,
            observedAt: Date(), state: nil, durability: nil)
        guard !failedLoad else { return unavailable }
        guard !SelfTest.isRunning || allowsHarnessPersistence else { return unavailable }
        do {
            guard let probe = try mirror.probeAuthority(includeTasks: false) else { return unavailable }
            try check(probe, witness: try? compatibilityData())
            return try mirror.workerPrimaryObservation(worker, probe: probe)
        } catch { return unavailable }
    }

    /// One ACP activity mutates only its bound timestamps. All other saved fields
    /// and order come from the same admitted canonical export representation.
    @discardableResult
    func saveActivity(_ tasks: [AgentTask], before: AgentTask, event: TaskJournalEventDraft,
                      worker: TaskWorkerWriteCondition) -> AgentTaskPersistenceResult {
        guard !failedLoad, !SelfTest.isRunning || allowsHarnessPersistence else {
            activityExport = nil; return .loadFailed
        }
        guard let cached = activityExport, cached.ids.count == tasks.count,
              let index = cached.ids.firstIndex(of: worker.taskID) else {
            return save(tasks, events: [event], worker: worker)
        }
        // Preserve exact ordered identity validation without allocating/mapping the
        // whole AgentTask array for every timestamp-only callback.
        for position in cached.ids.indices {
            guard cached.ids[position] == tasks[position].id else {
                return save(tasks, events: [event], worker: worker)
            }
        }
        do {
            // Read the actual witness every time. Only identical OWN bytes can reuse
            // its already-admitted header; changed bytes take the existing full check.
            let witness = try? compatibilityData()
            guard witness == cached.bytes else {
                activityExport = nil
                return save(tasks, events: [event], worker: worker)
            }
            let previous = try Self.decoder().decode(AgentTask.self, from: Self.encoder().encode(before))
            let retained = try Self.decoder().decode(AgentTask.self, from: cached.rows[index])
            let bytes = try Self.encoder().encode(tasks[index])
            let after = try Self.decoder().decode(AgentTask.self, from: bytes)
            var allowed = previous
            allowed.durability?.heartbeatAt = after.durability?.heartbeatAt
            allowed.durability?.lastProgressAt = after.durability?.lastProgressAt
            guard previous == retained, allowed == after,
                  event.detail != "acp.periodic" || after.durability?.lastProgressAt == previous.durability?.lastProgressAt else {
                activityExport = nil; return .jsonFailed
            }
            try TaskStore.validate([after])
            guard let probe = try mirror.probeAuthority(includeTasks: false), probe.authority != nil else {
                throw TaskStoreError.authorityConflict
            }
            try check(probe, witness: witness)
            try boundary("beforePrimaryCommit")
            let authority = try mirror.commitActivity(before: previous, after: after,
                probe: probe, event: event, worker: worker)
            expectedAuthority = authority; expectedIdentity = probe.identity
            activityExport = nil
            do {
                try boundary("primaryCommitted")
                var rows = cached.rows; rows[index] = bytes
                let exported = try Self.activityBytes(rows: rows, authority: authority, identity: probe.identity,
                    reserving: cached.bytes.count)
                try exported.write(to: storageURL, options: .atomic)
                activityExport = ActivityExport(authority: authority, identity: probe.identity,
                    bytes: exported, ids: cached.ids, rows: rows)
                return .saved
            } catch { return .exportFailed }
        } catch {
            activityExport = nil
            return failedLoad ? .loadFailed : .sqlFailed
        }
    }

    @discardableResult
    func save(_ tasks: [AgentTask], events: [TaskJournalEventDraft] = [],
              worker: TaskWorkerWriteCondition? = nil) -> AgentTaskPersistenceResult {
        // Reuse only the existing identical-own-witness check during this call.
        // The public cache still clears before validation and stays nil on refusal.
        let retainedExport = activityExport
        activityExport = nil
        guard !failedLoad else { return .loadFailed }
        guard !SelfTest.isRunning || allowsHarnessPersistence else { return .loadFailed }
        let canonical: [AgentTask]
        var canonicalWorker = worker
        do {
            canonical = try Self.decoder().decode([AgentTask].self, from: Self.encoder().encode(tasks))
            try TaskStore.validate(canonical)
            if let pending = worker?.typedPending {
                canonicalWorker?.typedPending = try Self.decoder().decode(TaskPendingInteraction.self,
                    from: Self.encoder().encode(pending))
            }
        } catch { return .jsonFailed }
        do {
            // Fresh save without load must discover/import authority too. Never infer a
            // legacy write from an unset cache; the full-snapshot API does not merge rows.
            if expectedAuthority == nil { _ = try load() }
            guard let probe = try mirror.probeAuthority(includeTasks: false), probe.authority != nil else {
                throw TaskStoreError.authorityConflict
            }
            try check(probe, witness: try? compatibilityData(), retainedExport: retainedExport)
            try boundary("beforePrimaryCommit")
            let authority = try mirror.commitAuthoritative(canonical, probe: probe, events: events, worker: canonicalWorker)
            expectedAuthority = authority
            expectedIdentity = probe.identity
            do {
                try boundary("primaryCommitted")
                let envelope = TaskHistoryExport(formatVersion: 1, preparedAuthority: authority,
                    fileIdentity: probe.identity, tasks: canonical)
                let bytes = try Self.encoder().encode(envelope)
                try bytes.write(to: storageURL, options: .atomic)
                activityExport = Self.activityExport(bytes, tasks: canonical, authority: authority, identity: probe.identity)
                return .saved
            } catch { return .exportFailed } // SQL committed; no cross-file atomicity claim.
        } catch { return failedLoad ? .loadFailed : .sqlFailed }
    }
}
