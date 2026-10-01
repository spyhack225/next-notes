import Foundation

enum AgentTaskPersistenceResult: Equatable {
    case saved, jsonFailed, mirrorFailed, loadFailed, sqlFailed, exportFailed

    var primaryCommitted: Bool { self == .saved || self == .exportFailed || self == .mirrorFailed }

    var diagnostic: String? {
        switch self {
        case .saved: nil
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
        if SelfTest.isRunning && allowsHarnessPersistence { try migrationBoundaryForTesting?(name) }
    }

    private func check(_ probe: TaskStoreAuthorityProbe, witness: Data?) throws {
        guard let authority = probe.authority else { throw TaskStoreError.authorityConflict }
        if let expectedAuthority {
            guard expectedAuthority == authority, expectedIdentity == probe.identity else {
                throw TaskStoreError.authorityConflict
            }
        }
        // SQL is selected before compatibility payload decoding. A readable header can
        // detect known rollback/replacement; absent/corrupt exports supply no witness.
        if let witness, let header = try? Self.decoder().decode(TaskHistoryExportHeader.self, from: witness) {
            guard header.formatVersion == 1, header.preparedAuthority.databaseID == authority.databaseID,
                  header.preparedAuthority.generation > 0,
                  header.preparedAuthority.generation <= authority.generation,
                  header.fileIdentity == probe.identity else { throw TaskStoreError.authorityConflict }
        }
    }

    func load() throws -> [AgentTask] {
        do {
            // Even reads through the default harness cannot tag/migrate/create owner SQL.
            if SelfTest.isRunning && !allowsHarnessPersistence {
                let data = try compatibilityData()
                let tasks: [AgentTask]
                if let data, let envelope = try? Self.decoder().decode(TaskHistoryExport.self, from: data) {
                    guard envelope.formatVersion == 1 else { throw TaskStoreError.invalidRecord }
                    tasks = envelope.tasks
                    try TaskStore.validate(tasks)
                } else { tasks = try Self.legacyTasks(data) }
                failedLoad = false
                return tasks
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

    /// Explicit fixture repair is separate from ordinary startup. A production repair
    /// action/card is still open; matching prepared UUID alone never triggers this path.
    func reconcilePreparedForTesting() throws {
        guard SelfTest.isRunning, allowsHarnessPersistence,
              let data = try compatibilityData() else { throw TaskStoreError.authorityConflict }
        let envelope = try Self.decoder().decode(TaskHistoryExport.self, from: data)
        try TaskStore.validate(envelope.tasks)
        guard envelope.formatVersion == 1, envelope.preparedAuthority.generation == 1,
              let probe = try mirror.probeAuthority(), probe.authority == nil,
              probe.identity == envelope.fileIdentity else { throw TaskStoreError.authorityConflict }
        try mirror.preflightImport(envelope.tasks, probe: probe)
        try mirror.reconcile(envelope.tasks, probe: probe, authority: envelope.preparedAuthority)
        expectedAuthority = envelope.preparedAuthority
        expectedIdentity = probe.identity
        failedLoad = false
    }

    @discardableResult
    func save(_ tasks: [AgentTask], events: [TaskJournalEventDraft] = []) -> AgentTaskPersistenceResult {
        guard !failedLoad else { return .loadFailed }
        guard !SelfTest.isRunning || allowsHarnessPersistence else { return .loadFailed }
        let canonical: [AgentTask]
        do {
            canonical = try Self.decoder().decode([AgentTask].self, from: Self.encoder().encode(tasks))
            try TaskStore.validate(canonical)
        } catch { return .jsonFailed }
        do {
            // Fresh save without load must discover/import authority too. Never infer a
            // legacy write from an unset cache; the full-snapshot API does not merge rows.
            if expectedAuthority == nil { _ = try load() }
            guard let probe = try mirror.probeAuthority(includeTasks: false), probe.authority != nil else {
                throw TaskStoreError.authorityConflict
            }
            try check(probe, witness: try? compatibilityData())
            try boundary("beforePrimaryCommit")
            let authority = try mirror.commitAuthoritative(canonical, probe: probe, events: events)
            expectedAuthority = authority
            expectedIdentity = probe.identity
            do {
                try boundary("primaryCommitted")
                let envelope = TaskHistoryExport(formatVersion: 1, preparedAuthority: authority,
                    fileIdentity: probe.identity, tasks: canonical)
                try Self.encoder().encode(envelope).write(to: storageURL, options: .atomic)
                return .saved
            } catch { return .exportFailed } // SQL committed; no cross-file atomicity claim.
        } catch { return failedLoad ? .loadFailed : .sqlFailed }
    }
}
