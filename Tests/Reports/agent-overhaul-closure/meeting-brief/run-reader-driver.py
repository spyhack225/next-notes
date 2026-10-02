#!/usr/bin/env python3
"""Copied actual assembler regression; prepare-only never invokes a compiler.

Run from the repository root. --original uses ae454a4's complete assembler and
its existing API; default uses the working tree. Both use the same frozen
dense corpus and assertions. Missing API/compile errors are HARNESS_ERROR, never red.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys

parser = argparse.ArgumentParser()
parser.add_argument('--original', action='store_true')
parser.add_argument('--prepare-only', action='store_true')
args = parser.parse_args()
root = Path.cwd()
here = Path(__file__).resolve().parent
source = root / 'Sources/NextNotes'
revision = 'ae454a4'
relative = 'Sources/NextNotes/Meetings/MeetingNotesContext.swift'
if args.original:
    assembler = subprocess.check_output(['git', 'show', revision + ':' + relative], text=True)
else:
    assembler = (root / relative).read_text()

def read(path):
    return (source / path).read_text()

def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

parts = {}
def actual(key, path, marker):
    value = declaration(read(path), marker)
    parts[key] = {'path': path, 'marker': marker,
                  'sha256': hashlib.sha256(value.encode()).hexdigest()}
    return value

kt = read('Knowledge/KnowledgeTools.swift')
collaborators = '''import Foundation
import UniformTypeIdentifiers
// Fixture value types only: no memory store/graph/calendar/provider is opened.
enum LLMProviderID { case appLLM, appleFoundation, openRouter, localServer }
struct Meeting { var id:UUID; var title:String; var start:Date; var attendees:[String] }
struct MemoryEntry: Sendable {
    enum Kind:String, CaseIterable, Sendable {case profile,note}
    enum Source:Sendable {case manual}
    var kind:Kind; var text:String; var source:Source; var createdAt:Date
}
struct NextMemoryItem:Sendable {
    enum Kind:String,Sendable {case project}
    var kind:Kind;var key:String;var value:String;var source:String;var updatedAt:Date;var useCount:Int
}
enum MemorySnapshotCache {static let defaultsEnabled=false}
@MainActor enum NextMemory {
    static var shared:Self.Type {fatalError("OWNER_MEMORY_FORBIDDEN")}
    static func recall(_ query:String,limit:Int,reader:LLMProviderID?)->(entries:[MemoryEntry],activity:[NextMemoryItem]) {fatalError("OWNER_MEMORY_FORBIDDEN")}
}
@MainActor enum KnowledgeIndexer {
    struct Settings {var graphCloudConsent=false}
    struct Graph {
        func decisionThreads() throws->[DecisionThread] {fatalError("OWNER_GRAPH_FORBIDDEN")}
        func relatedNodes(matching:String) throws->[KnowledgeGraphNode] {fatalError("OWNER_GRAPH_FORBIDDEN")}
    }
    static var shared:Self.Type {fatalError("OWNER_INDEX_FORBIDDEN")}
    static var toolContext:KnowledgeToolContext? {fatalError("OWNER_INDEX_FORBIDDEN")}
    static var graph:Graph? {fatalError("OWNER_GRAPH_FORBIDDEN")}
    static var settings:Settings {fatalError("OWNER_SETTINGS_FORBIDDEN")}
}
enum IndexedFoldersStore {
    static var shared:Self.Type {fatalError("OWNER_FOLDERS_FORBIDDEN")}
    static var cloudConsent:Bool {fatalError("OWNER_FOLDERS_FORBIDDEN")}
}
struct LiveFileRetrieval:FileRetrieving {
    var isAvailable:Bool {fatalError("OWNER_FILES_FORBIDDEN")}
    var folders:[String] {fatalError("OWNER_FILES_FORBIDDEN")}
    func find(query:String,category:FileCategory?,folder:String?,modifiedAfter:Date?,limit:Int)throws->[FileHit] {fatalError("OWNER_FILES_FORBIDDEN")}
    func tree(path:String,depth:Int,limit:Int)throws->(hits:[FileHit],total:Int) {fatalError("OWNER_FILES_FORBIDDEN")}
    func count(query:String)throws->Int {fatalError("OWNER_FILES_FORBIDDEN")}
}
struct KnowledgePreparedVectors:Equatable,Sendable {}
struct KnowledgeFacets:Sendable {}
protocol KnowledgeSearching:Sendable {
    func search(_ query:KnowledgeQuery)throws->[KnowledgeHit]
    func facets(_ query:KnowledgeQuery)throws->KnowledgeFacets
    func prepare(_ query:KnowledgeQuery)async->KnowledgeQuery
}
@MainActor struct KnowledgeToolContext {
    var searcher:any KnowledgeSearching
    var sourceTitle:(KnowledgeHit)->String? = {_ in nil}
    var meetingIDs:(String)->[String] = {UUID(uuidString:$0)==nil ? []:[$0]}
    var calendar:Calendar = .current
}
// No startTime fixture is supplied: unexpected timed rendering fails visibly.
extension Double {var counterText:String {fatalError("UNUSED_TIME_RENDERER")}}
'''
for key, path, marker in [
    ('GraphScope','Knowledge/KnowledgeTools.swift','enum KnowledgeGraphScope'),
    ('GraphNode','Knowledge/KnowledgeTools.swift','struct KnowledgeGraphNode'),
    ('DecisionRow','Knowledge/GraphStore.swift','struct DecisionThreadRow'),
    ('DecisionThread','Knowledge/GraphStore.swift','struct DecisionThread:'),
    ('KnowledgeKind','Knowledge/KnowledgeStore.swift','enum KnowledgeSourceKind'),
    ('KnowledgeFilter','Knowledge/KnowledgeSearch.swift','struct KnowledgeFilter'),
    ('KnowledgeQuery','Knowledge/KnowledgeSearch.swift','struct KnowledgeQuery'),
    ('KnowledgeHit','Knowledge/KnowledgeSearch.swift','struct KnowledgeHit'),
    ('KnowledgeError','Knowledge/KnowledgeTools.swift','enum KnowledgeToolError'),
    ('FileCategory','Knowledge/Files/FileIndex.swift','enum FileCategory'),
    ('FileHit','Knowledge/Files/FileIndex.swift','struct FileHit'),
    ('FileProtocol','Knowledge/Files/FileIndexTools.swift','protocol FileRetrieving'),
    ('FileScope','Knowledge/Files/FileIndexTools.swift','enum FileIndexScope'),
]:
    collaborators += '\n' + actual(key,path,marker) + '\n'
collaborators += '\nenum MemoryGuard {\n' + actual('MemoryTokens','Memory/MemoryGuard.swift','    static func tokens(') + '\n}\n'
collaborators += '\nextension FileRetrieving {\n' + actual('FileCountDefault','Knowledge/Files/FileIndexTools.swift','    func count(query: String) throws -> Int { 0 }') + '\n}\n'
collaborators += '\nenum FileIndexStore {\n' + actual('FileTokens','Knowledge/Files/FileIndex.swift','    static func tokens(') + '\n}\n'
collaborators += '\nenum KnowledgeFTSQuery {static let maxTokens=16\n' + actual('KnowledgeTokens','Knowledge/KnowledgeSearch.swift','    static func tokens(') + '\n}\n'
collaborators += '\nenum KnowledgeCitation {\n' + actual('CitationMarker','Knowledge/KnowledgeAsk.swift','    nonisolated static func marker(') + '\n}\n'
collaborators += '\n@MainActor enum KnowledgeToolExecutor {\n'
for name in ['defaultLimit','maxLimit','textLimit']:
    line = next(x for x in kt.splitlines() if x.strip().startswith('static let '+name+' '))
    collaborators += line + '\n'
for marker in ['    static func searchQuery(', '    static func search(_ query:',
               '    static func render(_ hits:', '    private static func value(',
               '    static func date(']:
    collaborators += actual('KnowledgeTool:' + marker,'Knowledge/KnowledgeTools.swift',marker) + '\n'
collaborators += '}\n@MainActor enum FileToolExecutor {\n'
files = read('Knowledge/Files/FileIndexTools.swift')
label = next(x for x in files.splitlines() if 'static let label ' in x)
collaborators += label + '\n' + actual('FileRender','Knowledge/Files/FileIndexTools.swift','    static func render(_ hits:') + '\n}\n'

fixture = (here / 'focused-fixture.swift.txt').read_text()
if args.original:
    # Invoke the historical API exactly as it existed. The intended window is
    # carried by the same harness input, but that API had nowhere to pass it.
    fixture = fixture.replace('''        let denseLarge = await denseAssembler.brief(for: meeting, reader: .appLLM,
                                                    contextTokens: 32_768)''',
                              '''        let denseLarge = await denseAssembler.brief(for: meeting, reader: .appLLM)''')
    fixture = fixture.replace('''        let longLarge = await longAssembler.brief(for: meeting, reader: .appLLM,
                                                  contextTokens: 32_768)''',
                              '''        let longLarge = await longAssembler.brief(for: meeting, reader: .appLLM)''')
fixtures = (here / 'focused-collaborators.swift.txt').read_text()
collaborators += fixtures
driver = '''import Foundation
@main struct ReaderDriver {
    @MainActor static func main() async {
        var failures:[String]=[]
        func check(_ name:String,_ condition:Bool) {if !condition {failures.append(name)}}
        let meeting=Meeting(id:UUID(),title:"Pricing review",start:Date(timeIntervalSince1970:1_750_000_000),attendees:["Sarah Chen","Ana Ruiz"])
        func assembler()->MeetingNotesContextAssembler {
            var value=MeetingNotesContextAssembler()
            value.memoryEnabled={true};value.recallMemory={_,_ in ([],[])}
            value.knowledge={nil};value.decisionThreads={[]};value.relatedNodes={_ in []}
            value.graphCloudConsent={false};value.filesCloudConsent={false}
            value.files={StubFileRetrieval()}
            return value
        }
        print("BRIEF_READER_INPUT window=32768 memory=8 decisions=20 nodes=30 passages=50 files=25")
''' + fixture + '''
        for failure in failures {print("BRIEF_READER_WRONG: \\(failure)")}
        print(failures.isEmpty ? "BRIEF_READER_DRIVER_OK" : "BRIEF_READER_DRIVER_FAILED: \\(failures.count) assertion(s)")
        if !failures.isEmpty {exit(1)}
    }
}
'''
folder = here / ('driver-original' if args.original else 'driver-current')
folder.mkdir(exist_ok=True)
for name, text in [('MeetingNotesContext.swift',assembler),('Collaborators.swift',collaborators),('Driver.swift',driver)]:
    (folder/name).write_text(text)
manifest = {'mode':'original' if args.original else 'working-tree',
            'original_revision':revision, 'assembler_sha256':hashlib.sha256(assembler.encode()).hexdigest(),
            'fixture_sha256':hashlib.sha256((here/'focused-fixture.swift.txt').read_bytes()).hexdigest(),
            'actual_extractions':parts,
            'fixture_boundaries':'value-only memory/Meeting; injected search/file corpus honoring limits; actual validation, render, token and consent methods; embedding/store/graph owner paths trap; no real provider, app consumer or latency claim'}
(folder/'input-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('BRIEF_READER_DRIVER_PREPARED:',folder,flush=True)
if args.prepare_only:
    sys.exit(0)
binary = folder / 'reader-driver'
result = subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',
                         str(folder/'MeetingNotesContext.swift'),str(folder/'Collaborators.swift'),
                         str(folder/'Driver.swift'),'-o',str(binary)])
if result.returncode:
    print('BRIEF_READER_DRIVER_HARNESS_ERROR: compilation failed; no product verdict')
    sys.exit(2)
sys.exit(subprocess.run([str(binary)]).returncode)
