from pathlib import Path
import hashlib,difflib,json
ROOT=Path('Sources/NextNotes'); OUT=Path('Tests/Reports/agent-overhaul-closure/next-implementation-review/p6-02b-artifact-production/full-pipeline')
def put(phase,rel,s):
 p=OUT/phase/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
def replace(s,a,b):
 assert s.count(a)==1,(a,s.count(a));return s.replace(a,b,1)
rel='Agent/Activity/AgentActivityProjector.swift';base=(ROOT/rel).read_text();put('baseline',rel,base)
common='''
struct AgentArtifactRow: Identifiable, Equatable, Sendable {
    let taskID: String
    let ordinal: Int
    let artifact: AgentArtifact
    let label: String
    let openURL: URL?
    var id: String { "\\(taskID):\\(ordinal)" }
}
enum AgentArtifactAction: Sendable { case open, copy }

'''
orig='''
    static func artifactLabel(_ artifact: AgentArtifact) -> String { artifact.value }
    static func artifactHeading(for task: AgentTask) -> String { "What I made" }
    static func artifactRows(for task: AgentTask) -> [AgentArtifactRow] {
        task.artifactRecords.enumerated().map { ordinal, artifact in
            let url = URL(string: artifact.value)
            let open = url?.scheme == "http" || url?.scheme == "https" ? url : nil
            return AgentArtifactRow(taskID: task.id, ordinal: ordinal, artifact: artifact,
                label: artifact.value, openURL: open)
        }
    }
'''
fix='''
    static func artifactLabel(_ artifact: AgentArtifact) -> String {
        if let title = artifact.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, isPublic(title) { return String(title.prefix(160)) }
        return artifact.value
    }
    static func artifactHeading(for task: AgentTask) -> String {
        guard task.status == .completed else { return "Related results" }
        let kinds = task.artifactRecords.map(\\.kind)
        if !kinds.isEmpty, kinds.allSatisfy({ ["documentCreated", "documentIDCreated"].contains($0) }) {
            return "What I made"
        }
        if !kinds.isEmpty, kinds.allSatisfy({ ["filePathRead", "fileURLRead", "documentRead", "documentIDRead"].contains($0) }) {
            return "What I read"
        }
        return "Results"
    }
    static func artifactRows(for task: AgentTask) -> [AgentArtifactRow] {
        task.artifactRecords.enumerated().map { ordinal, artifact in
            AgentArtifactRow(taskID: task.id, ordinal: ordinal, artifact: artifact,
                label: artifactLabel(artifact), openURL: artifactURL(artifact))
        }
    }
    private static func artifactURL(_ artifact: AgentArtifact) -> URL? {
        switch artifact.kind {
        case "documentCreated", "documentRead", "webPage":
            guard !artifact.value.contains(where: { $0.isWhitespace }),
                  let url = URL(string: artifact.value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            return url
        case "filePathRead", "filePathSaved":
            guard artifact.value.hasPrefix("/"), !artifact.value.utf8.contains(0) else { return nil }
            return URL(fileURLWithPath: artifact.value)
        case "fileURLRead", "fileURLSaved":
            guard let url = URL(string: artifact.value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { return nil }
            return url
        default: return nil
        }
    }
'''
pos=base.index('    @MainActor\n');put('original-scaffold',rel,base[:pos]+orig+base[pos:]+common);put('fixed-proposal',rel,base[:pos]+fix+base[pos:]+common)
rel='UI/Agent/AgentWorkingCard.swift';base=(ROOT/rel).read_text();assert hashlib.sha256(base.encode()).hexdigest()=='90130118f5d69acdded1e72d423cfa0877d740385bbe69119f17d0e8ae0dfb2d';put('baseline',rel,base)
# SAME consumer wiring/action boundary before both. Original projector preserves raw labels/URL-only open.
s=replace(base,'    @State private var expandedStep: String?','    @State private var expandedStep: String?\n    @State private var artifactNotice: String?')
s=replace(s,'                    openResult: task.artifacts.isEmpty ? nil : { openArtifacts() }','                    openResult: nil')
a=s.index('                if !task.artifacts.isEmpty {',s.index('private var terminalCard'));b=s.index('                // P1-6:',a);s=s[:a]+s[b:]
a=s.index('\n        }\n    }',s.index('private var terminalCard'))
s=s[:a]+'''
            if !task.artifactRecords.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(AgentActivityProjector.artifactHeading(for: task)).font(DS.Font.sectionLabel)
                    ForEach(Self.artifactRows(for: task)) { row in artifactRow(row) }
                    if let artifactNotice {
                        Text(artifactNotice).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                }
            }'''+s[a:]
a=s.index('    @ViewBuilder\n    private func artifactLink(');b=s.index('    // MARK: - P2-6',a)
s=s[:a]+'''    /// SAME projection and dispatcher used by actual row buttons and the isolated fixture.
    static func artifactRows(for task: AgentTask) -> [AgentArtifactRow] {
        AgentActivityProjector.artifactRows(for: task)
    }

    @MainActor
    static func performArtifactAction(_ action: AgentArtifactAction, task: AgentTask,
        row: AgentArtifactRow, open: (URL) -> Bool, copy: (String) -> Bool) -> Bool {
        guard row.taskID == task.id, task.artifactRecords.indices.contains(row.ordinal),
              task.artifactRecords[row.ordinal] == row.artifact else { return false }
        switch action {
        case .copy: return copy(row.artifact.value)
        case .open:
            // Recompute the SAME task-bound target at the click; never trust a forged/stale row URL.
            guard let current = artifactRows(for: task).first(where: { $0.ordinal == row.ordinal }),
                  let url = current.openURL else { return false }
            if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return false }
            return open(url)
        }
    }

    private func artifactRow(_ row: AgentArtifactRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(row.label).font(DS.Font.caption).textSelection(.enabled)
            Spacer(minLength: 0)
            if row.openURL != nil {
                Button("Open") { performArtifactAction(.open, row: row) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open \\(row.label)")
            }
            Button("Copy") { performArtifactAction(.copy, row: row) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \\(row.label)")
        }
    }

    private func performArtifactAction(_ action: AgentArtifactAction, row: AgentArtifactRow) {
        let accepted = Self.performArtifactAction(action, task: task, row: row,
            open: { NSWorkspace.shared.open($0) },
            copy: { value in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(value, forType: .string)
            })
        artifactNotice = accepted ? nil : "This result is unavailable. You can still copy its details."
    }

'''+s[b:]
put('original-scaffold',rel,s);put('fixed-proposal',rel,s)
# The original capture remains at the same backing seam. The doc producer only
# emits created descriptors after its real readback; uncertain outputs are neutral.
# Source/proposal hashes, exact patches remain off-source.
allrels=sorted(str(p.relative_to(OUT/'fixed-proposal')) for p in (OUT/'fixed-proposal').rglob('*.swift'))
for phase in ['original-scaffold','fixed-proposal']:
 patch=''
 for rel in allrels:
  a=(OUT/'baseline'/rel).read_text();b=(OUT/phase/rel).read_text()
  patch+=''.join(difflib.unified_diff(a.splitlines(True),b.splitlines(True),fromfile='a/Sources/NextNotes/'+rel,tofile='b/Sources/NextNotes/'+rel))
 (OUT/(phase+'.patch.txt')).write_text(patch)
patch=''
for rel in allrels:
 a=(OUT/'original-scaffold'/rel).read_text();b=(OUT/'fixed-proposal'/rel).read_text()
 patch+=''.join(difflib.unified_diff(a.splitlines(True),b.splitlines(True),fromfile='a/Sources/NextNotes/'+rel,tofile='b/Sources/NextNotes/'+rel))
(OUT/'original-to-fixed.patch.txt').write_text(patch)
print('Prepared consumer and',len(allrels),'source snapshots; exact parked UI baseline retained')
