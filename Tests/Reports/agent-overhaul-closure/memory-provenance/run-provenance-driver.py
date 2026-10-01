#!/usr/bin/env python3
"""Compile complete actual memory producers with isolated external collaborators.

--original reads producer files from the pre-P4-07a commit. The same current
MemorySelfTest.lineageFailures drives both versions; no model, store from the
owner, runtime, grant, account or app process is touched.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
SOURCE = ROOT / 'Sources/NextNotes'
ORIGINAL = '5de382acfc779c019f558bd30f924373d2a1b38c'

def source(relative):
    if '--original' in sys.argv:
        return subprocess.check_output(['git', 'show', ORIGINAL + ':Sources/NextNotes/' + relative], cwd=ROOT, text=True)
    return (SOURCE / relative).read_text()

collaborators = '''import Foundation
import OSLog
enum SelfTest { static let isRunning = true }
enum AppIdentity { static let applicationSupportDirectory = URL(fileURLWithPath:"/invalid-owner-store-never-used") }
enum Log { static let agent = Logger(subsystem:"nextnotes.memory.driver", category:"fixture") }
enum ActionAuthority { case user, memoryReview }
struct ResolvedPerson: Equatable, Sendable { var id:String; var name:String; var aliases:[String] }
enum MemoryPeople: Equatable, Sendable { case graphOff, notLoaded, resolved([ResolvedPerson]) }
@MainActor enum PersonResolutionService {
    static var shared: Self.Type { Self.self }
    static func memoryPeople() -> MemoryPeople { fatalError("no graph access") }
}
@MainActor enum KnowledgeIndexer {
    struct Settings { let graphCloudConsent = false }
    static var shared: Self.Type { Self.self }
    static var settings: Settings { fatalError("no owner settings") }
}
enum LLMProviderID { case local, cloud }
enum KnowledgeGraphScope {
    static let reader: LLMProviderID? = nil
    static func mayRead(reader:LLMProviderID?, cloudConsent:Bool) -> Bool { false }
}
@MainActor enum DictionaryStore {
    struct Entry { enum Kind {case term, correction};var isEnabled:Bool;var kind:Kind;var write:String;var hear:String }
    static var shared: Self.Type { Self.self }
    static var entries:[Entry] { fatalError("no dictionary reads") }
}
@MainActor enum MeetingStore {
    struct Meeting {var id:UUID;var title:String;var attendees:[String];var isProvisionalTitle:Bool}
    static var shared: Self.Type { Self.self }
    static var meetings:[Meeting] {fatalError("no meeting reads")}
    static func meeting(id:UUID)->Meeting? {fatalError("no meeting lookup")}
}
@MainActor enum AgentTaskManager {
    struct Task {var contextReferences:[String];var acpCLI:String;var id:String}
    static var shared: Self.Type {Self.self}
    static var tasks:[Task] {fatalError("no owner tasks")}
}
struct NotionAvatarConfig: Codable, Equatable, Sendable {}
enum MemoryImportPlanner {static func preview(_ text:String)->String {fatalError("no importer")}}
enum AgentNow {enum Shape:Sendable {case none,compact,full,dateOnly,unattended}}
enum PersonaStore {static let shortCardLimit=400;static let fullLimit=4000}
struct AgentTool {
    enum Namespace:String {case memory}
    enum Risk {case modify,read}
    enum ExecutionMode {case immediate}
    struct Parameter {init(name:String,description:String,isRequired:Bool=true){}}
    var name:String
    var id:String {"memory."+name}
    static func native(namespace:Namespace,name:String,description:String,risk:Risk,
                       parameters:[Parameter],executionMode:ExecutionMode = .immediate,title:String)->Self {Self(name:name)}
}
struct AgentToolResult {var summary:String;var reference:String?=nil;var verification:String?=nil}
enum AgentError:Error {case unknownTool(String)}
enum AgentSpeechPolicy {
    enum MemoryAction {case alreadyKnown,saved,updated,forgotten}
    static func memoryConfirmation(_ action:MemoryAction,text:String)->String {"fixture accepted"}
}
struct KnowledgeRecall {static let sectionLabel="fixture";func passages(for query:String)->String? {fatalError("no knowledge read")}}
'''
prompt = (SOURCE/'Persona/AgentPromptContext.swift').read_text()
# Complete, byte-identical production path budgets; no rewritten test budget.
prompt = prompt[prompt.index('enum AgentPromptPath:'):prompt.index('/// The one prompt assembler')]
if '--original' in sys.argv:
    test = (pathlib.Path(__file__).parent/'original-regression.swift').read_text()
else:
    test = (SOURCE/'Memory/MemorySelfTest.swift').read_text()
    test = test[test.index('    static func lineageFailures('):test.index('    // MARK: - The tool path')]
collaborators += '\n' + prompt + '\n@MainActor enum MemorySelfTest {\n' + test + '\n}\n'
collaborators += '''
@main struct ProvenanceDriver {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesMemoryProvenance-\\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let failures = MemorySelfTest.lineageFailures(directory:root)
        for failure in failures {print("MEMORY_LINEAGE_WRONG: \\(failure)")}
        print(failures.isEmpty ? "MEMORY_LINEAGE_DRIVER_OK" : "MEMORY_LINEAGE_DRIVER_FAILED: \\(failures.count) assertion(s)")
        if !failures.isEmpty {exit(1)}
    }
}
'''
with tempfile.TemporaryDirectory(prefix='nextnotes-memory-provenance-compile-') as temporary:
    folder = pathlib.Path(temporary)
    paths=[]
    for relative in ['Memory/NextMemory.swift','Memory/MemoryGuard.swift','Memory/MemoryTools.swift','Memory/Portability/MemoryPackage.swift']:
        destination=folder/pathlib.Path(relative).name
        destination.write_text(source(relative));paths.append(destination)
    lineage=SOURCE/'Memory/Consolidation/MemoryLineage.swift'
    if '--original' not in sys.argv and lineage.exists():
        destination=folder/lineage.name;destination.write_text(lineage.read_text());paths.append(destination)
    stub=folder/'Collaborators.swift';stub.write_text(collaborators)
    binary=folder/'provenance-driver'
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(stub),*[str(p) for p in paths],'-o',str(binary)],check=True)
    sys.exit(subprocess.run([str(binary)]).returncode)
