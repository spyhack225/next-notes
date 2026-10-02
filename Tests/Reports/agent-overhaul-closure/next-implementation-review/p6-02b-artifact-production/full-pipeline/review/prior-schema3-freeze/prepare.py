from pathlib import Path
import hashlib,json,difflib
ROOT=Path('Sources/NextNotes'); OUT=Path('Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-02b-artifact-production/full-pipeline')
original={};fixed={};baseline={}
def read(rel):
 p=ROOT/rel;s=p.read_text();baseline[rel]=s;return s
def replace(s,a,b):
 assert s.count(a)==1,(a,s.count(a));return s.replace(a,b,1)
artifact='''/// One ordered result descriptor. The value is the existing path/ID/link payload.
/// Kind/title come from a producer; unknown strings never gain inferred authority.
struct AgentArtifact: Codable, Equatable, Sendable {
    var value: String
    var kind: String
    var title: String?
    init(_ value: String, kind: String = "link", title: String? = nil) {
        self.value = value; self.kind = kind; self.title = title
    }
    var isLegacy: Bool { kind == "link" && title == nil }

    /// Preserve the existing ordered paths, including duplicates, on legacy mutations.
    static func replacingValues(_ values: [String], in old: [Self]) -> [Self] {
        var used = Set<Int>()
        return values.enumerated().map { ordinal, value in
            let index: Int?
            if old.indices.contains(ordinal), old[ordinal].value == value, !used.contains(ordinal) {
                index = ordinal
            } else { index = old.indices.first { !used.contains($0) && old[$0].value == value } }
            if let index { used.insert(index); return old[index] }
            return Self(value)
        }
    }
    /// The backend's old ordered list stays first; captured duplicates enrich in place.
    static func merging(_ captured: [Self], into initial: [Self]) -> [Self] {
        var records = initial
        for record in captured {
            if let index = records.firstIndex(where: { $0.value == record.value }) {
                if records[index].isLegacy && !record.isLegacy { records[index] = record }
            } else { records.append(record) }
        }
        return records
    }
}

'''
rel='Agent/AgentModels.swift';s=read(rel);s=replace(s,'/// What a tool produced, once it ran.\n',artifact+'/// What a tool produced, once it ran.\n')
s=replace(s,'    var outcomeUnknown: Bool = false','    var outcomeUnknown: Bool = false\n    let artifactRecords: [AgentArtifact]')
s=replace(s,'verification: String? = nil, outcomeUnknown: Bool = false) {','verification: String? = nil, outcomeUnknown: Bool = false,\n         artifactRecords: [AgentArtifact]? = nil) {')
s=replace(s,'        self.outcomeUnknown = outcomeUnknown\n','''        self.outcomeUnknown = outcomeUnknown
        self.artifactRecords = artifactRecords ?? [reference, link?.absoluteString]
            .compactMap { $0 }.map { AgentArtifact($0) }
''');original[rel]=fixed[rel]=s
rel='Agent/Tasks/AgentTask.swift';s=read(rel);s=replace(s,'    var artifacts: [String]\n','''    var artifactRecords: [AgentArtifact]
    /// Compatibility view of the single canonical collection, not a second list.
    var artifacts: [String] {
        get { artifactRecords.map(\\.value) }
        set { artifactRecords = AgentArtifact.replacingValues(newValue, in: artifactRecords) }
    }
''');s=replace(s,'        self.artifacts = artifacts\n','        self.artifactRecords = artifacts.map { AgentArtifact($0) }\n')
s=replace(s,'        case result, artifacts, tool, arguments, meetingID, backend, failure, acpCLI','        case result, artifacts, artifactRecords, tool, arguments, meetingID, backend, failure, acpCLI')
s=replace(s,'        artifacts = try container.decodeIfPresent([String].self, forKey: .artifacts) ?? []','''        let values = try container.decodeIfPresent([String].self, forKey: .artifacts) ?? []
        let records = try container.decodeIfPresent([AgentArtifact].self, forKey: .artifactRecords)
        guard records == nil || records?.map(\\.value) == values else {
            throw DecodingError.dataCorruptedError(forKey: .artifactRecords, in: container,
                debugDescription: "Artifact metadata does not match the ordered values")
        }
        artifactRecords = records ?? values.map { AgentArtifact($0) }''')
# Custom encode preserves the old payload keys and omits neutral metadata.
req=['id','objective','source','createdAt','contextReferences','status','progress','arguments','backend','acpCLI']
opt=['result','tool','meetingID','failure','compatibilityCommand','compatibilityCLI','compatibilityDirectory','scheduleID','durability','pendingInteraction']
encode='''
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
'''+''.join(f'        try container.encode({k}, forKey: .{k})\n' for k in req)+''.join(f'        try container.encodeIfPresent({k}, forKey: .{k})\n' for k in opt)+'''        try container.encode(artifacts, forKey: .artifacts)
        if artifactRecords.contains(where: { !$0.isLegacy }) {
            try container.encode(artifactRecords, forKey: .artifactRecords)
        }
    }
'''
s=replace(s,'\n}\n\nenum AgentContextReference {',encode+'\n}\n\nenum AgentContextReference {');original[rel]=fixed[rel]=s
rel='Agent/Tasks/AgentArtifactLedger.swift';s=read(rel)
# Original scaffold retains the current string collection and take behavior.
pos=s.rfind('\n}')
original[rel]=s[:pos]+'''
    static func takeRecords(taskID: String?) -> [AgentArtifact] {
        take(taskID: taskID).map { AgentArtifact($0) }
    }
    static func peekRecords(taskID: String?) -> [AgentArtifact] {
        peek(taskID: taskID).map { AgentArtifact($0) }
    }
'''+s[pos:]
fixed[rel]='''import Foundation

/// The existing single ordered artifact collection, with producer metadata retained.
enum AgentArtifactLedger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byTask: [String: [AgentArtifact]] = [:]

    static func capture(taskID: String?, artifact: String) {
        capture(taskID: taskID, record: AgentArtifact(artifact))
    }
    private static func capture(taskID: String?, record: AgentArtifact) {
        // Legacy capture keeps its established trim; typed locations are exact producer values.
        let value = record.isLegacy ? record.value.trimmingCharacters(in: .whitespacesAndNewlines) : record.value
        guard let taskID, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var record = record; record.value = value
        lock.lock(); defer { lock.unlock() }
        byTask[taskID] = AgentArtifact.merging([record], into: byTask[taskID] ?? [])
    }
    static func capture(taskID: String?, result: AgentToolResult) {
        for record in result.artifactRecords { capture(taskID: taskID, record: record) }
    }
    static func takeRecords(taskID: String?) -> [AgentArtifact] {
        guard let taskID else { return [] }
        lock.lock(); defer { lock.unlock() }
        return byTask.removeValue(forKey: taskID) ?? []
    }
    static func peekRecords(taskID: String?) -> [AgentArtifact] {
        guard let taskID else { return [] }
        lock.lock(); defer { lock.unlock() }
        return byTask[taskID] ?? []
    }
    static func take(taskID: String?) -> [String] { takeRecords(taskID: taskID).map(\\.value) }
    static func peek(taskID: String?) -> [String] { peekRecords(taskID: taskID).map(\\.value) }
}
'''
rel='Agent/Tasks/AgentTaskManager.swift';s=read(rel);s=replace(s,'    var artifacts: [String]\n    var failure: String?','''    var artifactRecords: [AgentArtifact]
    var artifacts: [String] {
        get { artifactRecords.map(\\.value) }
        set { artifactRecords = AgentArtifact.replacingValues(newValue, in: artifactRecords) }
    }
    var failure: String?

    init(status: AgentTaskStatus, progress: String, result: String?, artifacts: [String], failure: String?) {
        self.status = status; self.progress = progress; self.result = result
        self.artifactRecords = artifacts.map { AgentArtifact($0) }; self.failure = failure
    }
    static func completed(_ result: String, artifactRecords: [AgentArtifact]) -> AgentTaskOutcome {
        var outcome = completed(result, artifacts: artifactRecords.map(\\.value))
        outcome.artifactRecords = artifactRecords
        return outcome
    }''');original[rel]=s
s=replace(s,'            let captured = AgentArtifactLedger.take(taskID: id)','            let captured = AgentArtifactLedger.takeRecords(taskID: id)')
s=replace(s,'                item.artifacts = outcome.artifacts + captured.filter { !outcome.artifacts.contains($0) }','                item.artifactRecords = AgentArtifact.merging(captured, into: outcome.artifactRecords)')
s=replace(s,'        let captured = AgentArtifactLedger.take(taskID: taskID)','        let captured = AgentArtifactLedger.takeRecords(taskID: taskID)')
s=replace(s,'''            for artifact in captured where !item.artifacts.contains(artifact) {
                item.artifacts.append(artifact)
            }''','            item.artifactRecords = AgentArtifact.merging(captured, into: item.artifactRecords)')
s=replace(s,'        let lines = "What I made for you:\\n"\n            + task.artifacts.map { "\\u{2022} \\($0)" }.joined(separator: "\\n")','''        let lines = AgentActivityProjector.artifactHeading(for: task) + ":\\n"
            + task.artifactRecords.map { "\\u{2022} \\(AgentActivityProjector.artifactLabel($0))" }.joined(separator: "\\n")''');fixed[rel]=s
rel='Agent/Backend/LocalAgentBackend.swift';s=read(rel);original[rel]=s
start=s.index('        var artifacts: [String] = []\n');end=s.index('\n    }',start)
fixed[rel]=s[:start]+'        return .completed(result.summary, artifactRecords: result.artifactRecords)'+s[end:]
rel='Agent/WorkspaceToolRunner.swift';s=read(rel);original[rel]=s
needle='            verification: verified ? "Read back the created document\'s title and content" : nil\n'
fixed[rel]=replace(s,needle,needle.rstrip('\n')+''',
            artifactRecords: verified ? [AgentArtifact(id, kind: "documentIDCreated", title: title)]
                + (documentURL(id).map { [AgentArtifact($0.absoluteString, kind: "documentCreated", title: title)] } ?? []) : nil
''')
rel='Shell/FilesystemExecutor.swift';s=read(rel);original[rel]=s
s=replace(s,'        return AgentToolResult(summary: clipped, reference: url.path)','''        return AgentToolResult(summary: clipped, reference: url.path,
            artifactRecords: [AgentArtifact(url.path, kind: "filePathRead", title: url.lastPathComponent)])''')
s=replace(s,'        return AgentToolResult(summary: "Wrote \\(url.lastPathComponent).", reference: url.path)','''        return AgentToolResult(summary: "Wrote \\(url.lastPathComponent).", reference: url.path,
            artifactRecords: [AgentArtifact(url.path, kind: "filePathSaved", title: url.lastPathComponent)])''');fixed[rel]=s
rel='Agent/Tools/AgentToolExecutor.swift';s=read(rel)
# Same exact common CLI backing seam retained before both; no production routing change.
s=replace(s,'    @MainActor static var fireOverrideForTesting: FakeToolRun?','    @MainActor static var fireOverrideForTesting: FakeToolRun?\n    @MainActor static var workspaceCLIForTesting: (any WorkspaceCLIRunning)?')
s=replace(s,'        case .workspace:\n            let proposal = AgentProposal(','''        case .workspace:
            if SelfTest.isRunning, let cli = workspaceCLIForTesting {
                let proposal = AgentProposal(meetingID: UUID(), tool: tool.name,
                    arguments: arguments, rationale: "", accountTag: nil,
                    startsAt: proposalStartsAt(toolName: tool.name, arguments: arguments))
                return try await WorkspaceToolRunner.run(proposal, cli: cli)
            }
            let proposal = AgentProposal(''');original[rel]=fixed[rel]=s
rel='Agent/Tasks/Durable/TaskStore.swift';s=read(rel)
s=replace(s,'            guard !task.id.isEmpty, task.createdAt.timeIntervalSince1970.isFinite else { return false }',
'''            guard !task.id.isEmpty, task.createdAt.timeIntervalSince1970.isFinite,
                  task.artifactRecords.allSatisfy({ !$0.kind.isEmpty && !$0.kind.utf8.contains(0) }) else { return false }''')
original[rel]=s
# Same existing SQL transaction and columns, full metadata follows each ordinal.
a=s.index('                // Legacy links have neutral metadata until P6-02b');b=s.index('\n            }',a)
s=s[:a]+'''                let record = task.artifactRecords[ordinal]
                try Self.run(db, """
                    INSERT INTO task_artifact(task_id,path,ordinal,added_at,kind,title)
                    VALUES(?,?,?,CAST(? AS INTEGER),?,?)
                    ON CONFLICT(task_id,ordinal) DO UPDATE SET
                      kind=CASE WHEN excluded.kind='link' AND excluded.title IS NULL
                        AND path=excluded.path AND kind NOT LIKE 'artifact-v1:%' THEN kind ELSE excluded.kind END,
                      title=CASE WHEN excluded.kind='link' AND excluded.title IS NULL
                        AND path=excluded.path AND kind NOT LIKE 'artifact-v1:%' THEN title ELSE excluded.title END,
                      path=excluded.path
                    """, [.text(task.id), .text(path), .integer(Int64(ordinal)),
                        .real(task.createdAt.timeIntervalSince1970),
                        .text(record.isLegacy ? "link" : "artifact-v1:" + record.kind), .optionalText(record.title)])'''+s[b:]
s=replace(s,'                var artifacts: [String] = []','                var artifactRecords: [AgentArtifact] = []')
s=replace(s,'                          sqlite3_column_int64(artifactsStatement, 1) == Int64(artifacts.count),','                          sqlite3_column_int64(artifactsStatement, 1) == Int64(artifactRecords.count),')
s=replace(s,'''                          try Self.text(artifactsStatement, 3) != nil else { throw TaskStoreError.invalidRecord }
                    _ = try Self.text(artifactsStatement, 4)
                    artifacts.append(path)''','''                          let kind = try Self.text(artifactsStatement, 3) else { throw TaskStoreError.invalidRecord }
                    let title = try Self.text(artifactsStatement, 4)
                    if kind.hasPrefix("artifact-v1:") {
                        let semantic = String(kind.dropFirst("artifact-v1:".count))
                        guard !semantic.isEmpty, !semantic.utf8.contains(0) else { throw TaskStoreError.invalidRecord }
                        artifactRecords.append(AgentArtifact(path, kind: semantic, title: title))
                    } else if kind.range(of: "^artifact-v[0-9]+:", options: .regularExpression) != nil {
                        // An unknown future representation is not silently discarded.
                        throw TaskStoreError.invalidRecord
                    } else {
                        // Existing arbitrary diagnostic kind/title stay noncanonical.
                        artifactRecords.append(AgentArtifact(path))
                    }''')
s=replace(s,'                let task = AgentTask(id: id,','                var task = AgentTask(id: id,')
s=replace(s,'progress: try required(5), result: try Self.text(statement, 17), artifacts: artifacts,','progress: try required(5), result: try Self.text(statement, 17), artifacts: artifactRecords.map(\\.value),')
s=replace(s,'                tasks.append(task)','                task.artifactRecords = artifactRecords\n                tasks.append(task)')
s=replace(s,'            return row.artifacts.starts(with: task.artifacts)',
'''            return row.artifacts.starts(with: task.artifacts)
                && Array(row.artifactRecords.prefix(task.artifactRecords.count)) == task.artifactRecords''')
fixed[rel]=s
# Projector/action and UI bodies added below by the second preparation stage.
for phase,data in [('original-scaffold',original),('fixed-proposal',fixed),('baseline',baseline)]:
 for rel,s in data.items():
  p=OUT/phase/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
manifest={'status':'OFF-SOURCE, UNCOMPILED, NOT MOUNTED; UI and common fixture preparation still in progress','source_sha256':{k:hashlib.sha256(v.encode()).hexdigest() for k,v in baseline.items()}}
(OUT/'preparation-stage1.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Prepared',len(fixed),'off-source pipeline snapshots; Source untouched')
