#!/usr/bin/env python3
"""Compile copied production latency/store sources; models/audio/app bootstrap are excluded.
The main latency flag's validators are extracted verbatim. An independent checked-lock
copy records lock imbalance without deliberately invoking an undefined native unlock.
No repository producer source is mutated by this driver.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
SOURCES = ROOT / 'Sources/NextNotes'
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--checked-lock', action='store_true')
parser.add_argument('--check-snapshot-thread', action='store_true')
parser.add_argument('--full-instrumentation', action='store_true')
parser.add_argument('--consumer-contracts', action='store_true')
parser.add_argument('--mutate-zero-stall', action='store_true')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
paths = [
 'Agent/Voice/VoiceLatencyTimeline.swift', 'Support/MetricsStore.swift',
 'Support/Usage/UsageLog.swift', 'Support/Usage/UsageRecord.swift',
 'Support/LatencyTrace.swift', 'Agent/Voice/MainActorStallProbe.swift', 'Agent/Voice/VoiceLatencySelfTest.swift'
]
manifest = {p: hashlib.sha256((SOURCES/p).read_bytes()).hexdigest() for p in paths}
(args.output/'source-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')

def method(text, name):
    start = text.index('    private static func '+name)
    brace = text.index('{', start)
    depth = 1
    end = brace+1
    # These methods contain only string interpolation balanced braces, which remain paired.
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end].replace('private static func', 'static func', 1)

stubs = '''import Foundation
import os
// App-bootstrap identities only: actual stores still enforce their own temp harness path.
enum SelfTest {
 static let isRunning = true
 static let requested: String? = nil
 static func diagnostic(_ value: String) { print(value) }
}
enum AppIdentity {
 static let applicationSupportDirectory = FileManager.default.temporaryDirectory
   .appendingPathComponent("UNUSED-LatencyDriver")
}
enum Log { static let metrics = Logger(subsystem: "LatencyDriver", category: "metrics") }
// Unrelated error classification never runs in this instrumentation driver.
'''
checked = '''
final class CheckedLock: @unchecked Sendable {
 private let underlying = NSLock()
 private var held = false
 nonisolated(unsafe) static var unmatchedUnlocks = 0
 func lock() { underlying.lock(); held = true }
 func unlock() {
   if !held { Self.unmatchedUnlocks += 1; return }
   held = false; underlying.unlock()
 }
}
'''
main = '''import Foundation
@main struct Driver {
 static func main() {
   let timeline = VoiceLatencyTimeline()
   let session = UUID()
   timeline.beginSession(session)
   var at = VoiceLatencyTimeline.nowNanos()
   func mark(_ mark: VoiceMark) { at += 1_000_000; timeline.mark(mark, at: at) }
   mark(.voiceOnset)
   timeline.attachTurnIDs(turnID: UUID(), conversationID: UUID())
   mark(.lastVoice); mark(.eouRaw); mark(.eouCallback); mark(.eouConfirmed)
   mark(.endpoint); timeline.note("endpoint_source", "localEOU")
   mark(.frontendRequest); mark(.schedulerAcquired); mark(.routeDone)
   mark(.frontendFirstToken); timeline.note("speculation", "miss reason=no-slot")
   mark(.firstClauseEnqueued); mark(.ttsFirstPCM); mark(.firstAudible)
   MetricsStore.shared.flushForTesting(); UsageLog.shared.flush()
   var wrong: [String] = []
   if let turn = timeline.closedTurnsForTesting().last {
     wrong += Consumer.validateStore(turn: turn, index: 1)
     let rows = MetricsStore.load(from: MetricsStore.shared.fileURL).filter {
       $0.correlation?.sessionID == session && $0.correlation?.revision == turn.number
     }
     let stall = rows.filter { $0.name == .voiceMainActorStall }
     print("LATENCY_INSTRUMENTATION_STALL rows=\\(stall.count) memory=\\(turn.mainStallSeconds)")
     if stall.count != 1 || stall.first?.durationSeconds != 0 {
       wrong.append("healthy zero-stall turn must persist exactly one zero-duration stall row")
     }
     let summaries = UsageLog.shared.load().filter { $0.turnID == turn.turnID && $0.pass == "turn" }
     if summaries.count != 1 || summaries.first?.stages?["main_actor_stall"] != 0 {
       wrong.append("healthy zero-stall summary disagrees with its persistent span")
     }
   } else { wrong.append("no closed turn") }
   CHECKED_ASSERTION
   for issue in wrong { print("LATENCY_INSTRUMENTATION_WRONG: \\(issue)") }
   print(wrong.isEmpty ? "LATENCY_INSTRUMENTATION_OK" : "LATENCY_INSTRUMENTATION_FAILED: \\(wrong.count)")
   let temp = MetricsStore.shared.directory
   try? FileManager.default.removeItem(at: temp)
   exit(wrong.isEmpty ? 0 : 1)
 }
}
'''
main = main.replace('CHECKED_ASSERTION', '''
   let threads = SnapshotThreads.snapshot()
   print("LATENCY_INSTRUMENTATION_SNAPSHOTS main=\\(threads.main) worker=\\(threads.worker)")
   if threads.main > 0 || threads.worker == 0 { wrong.append("voice producer sampled ProcessSnapshot on the stamping thread") }
   CHECKED_ASSERTION
''' if args.check_snapshot_thread else 'CHECKED_ASSERTION')
main = main.replace('CHECKED_ASSERTION', '''
   print("LATENCY_INSTRUMENTATION_LOCK unmatched=\\(CheckedLock.unmatchedUnlocks)")
   if CheckedLock.unmatchedUnlocks != 0 { wrong.append("producer unlocks a lock it no longer holds") }
''' if args.checked_lock else '')
with tempfile.TemporaryDirectory(prefix='NextNotesLatencyDriver-') as scratch:
    scratch = pathlib.Path(scratch)
    files = []
    if args.check_snapshot_thread:
        stubs += '''
final class SnapshotThreads: @unchecked Sendable {
 private static let shared = SnapshotThreads()
 private let lock = NSLock()
 private var main = 0
 private var worker = 0
 static func record() {
   shared.lock.lock(); defer { shared.lock.unlock() }
   if Thread.isMainThread { shared.main += 1 } else { shared.worker += 1 }
 }
 static func snapshot() -> (main: Int, worker: Int) {
   shared.lock.lock(); defer { shared.lock.unlock() }; return (shared.main, shared.worker)
 }
}
'''
    for path in paths[:-1]:
        value = (SOURCES/path).read_text()
        if path.endswith('UsageRecord.swift'):
            start = value.index('    static func classify(')
            brace = value.index('{',start); depth=1; end=brace+1
            while depth:
                if value[end]=='{': depth+=1
                elif value[end]=='}': depth-=1
                end+=1
            value = value[:start]+'    static func classify(_ error: Error) -> UsageErrorClass { .other }'+value[end:]
        if path.endswith('LatencyTrace.swift') and args.check_snapshot_thread:
            value = value.replace('    static func current() -> ProcessSnapshot {', '    static func current() -> ProcessSnapshot {\n        SnapshotThreads.record()', 1)
        if path.endswith('VoiceLatencyTimeline.swift'):
            if args.checked_lock: value = value.replace('private let lock = NSLock()', 'private let lock = CheckedLock()')
            if args.mutate_zero_stall:
                marker = '        case .stall:\n'
                start = value.index(marker, value.index('private static func span('))+len(marker)
                value = value[:start]+'            guard turn.maxStallNanos > 0 else { return nil }\n'+value[start:]
        target = scratch/pathlib.Path(path).name
        target.write_text(value); files.append(str(target))
    test_source = (SOURCES/paths[-1]).read_text()
    methods = ['validateStore']
    if args.consumer_contracts: methods += ['validate']
    if args.full_instrumentation:
        methods += ['instrumentationProblems', 'selfTestEmission', 'selfTestZeroStall',
                    'selfTestAbsentStages', 'selfTestDiscard', 'selfTestUsageRow', 'stampCompleteTurn',
                    'selfTestRequiredStagesAndCount', 'selfTestStoreTurnIdentity', 'validate']
        main = main.replace(' static func main() {', ' @MainActor static func main() async {')
        main = main.replace('   CHECKED_ASSERTION', '   CHECKED_ASSERTION')
        main = main.replace('   for issue in wrong', '   wrong += await Consumer.instrumentationProblems()\n   for issue in wrong')
    if args.consumer_contracts:
        # Feed the old validator the same turn/stage inputs it receives in oneRun; the old
        # signature had no committed-count/mode argument, which is precisely its omission.
        new_contract = 'committedCount:' in method(test_source, 'validate')
        validate = 'Consumer.validate(turn: turn, index: 1, reply: "A brief answer"' + (', committedCount: count, separateRoute: separate' if new_contract else '') + ')'
        body = r'''
   func checkContract(omit: Set<VoiceMark>, hit: Bool, separate: Bool, count: Int, expectedInvalid: Bool) {
     let probe = VoiceLatencyTimeline()
     probe.beginSession(UUID())
     var t = VoiceLatencyTimeline.nowNanos()
     let marks: [VoiceMark] = [.voiceOnset, .lastVoice, .eouRaw, .eouCallback, .eouConfirmed,
       .endpoint, .frontendRequest, .schedulerAcquired, .routeDone, .frontendFirstToken,
       .firstClauseEnqueued, .ttsFirstPCM]
     for m in marks { t += 1_000_000; if !omit.contains(m) { probe.mark(m, at: t) } }
     probe.note("endpoint_source", "localEOU")
     probe.note("speculation", hit ? "hit headstart=0.1" : "miss reason=no-slot")
     probe.mark(.firstAudible, at: t + 1_000_000)
     guard let turn = probe.closedTurnsForTesting().last else { wrong.append("contract case produced no turn"); return }
     let verdict = VALIDATE
     print("LATENCY_CONTRACT omit=\(omit.map(\.rawValue).sorted()) hit=\(hit) separate=\(separate) count=\(count) errors=\(verdict.count)")
     if verdict.isEmpty == expectedInvalid { wrong.append("consumer accepted missing stages/count or rejected valid mode") }
   }
   checkContract(omit: [.schedulerAcquired, .routeDone], hit: false, separate: true, count: 1, expectedInvalid: true)
   checkContract(omit: [.schedulerAcquired, .routeDone], hit: true, separate: true, count: 1, expectedInvalid: false)
   checkContract(omit: [.routeDone], hit: false, separate: false, count: 1, expectedInvalid: false)
   checkContract(omit: [], hit: false, separate: true, count: 0, expectedInvalid: true)
   checkContract(omit: [], hit: false, separate: true, count: 2, expectedInvalid: true)
   if let turn = timeline.closedTurnsForTesting().last {
     let next = VoiceClosedTurn(number: turn.number + 1, sessionID: turn.sessionID,
       turnID: UUID(), conversationID: turn.conversationID, reason: turn.reason,
       marks: turn.marks, notes: turn.notes, maxStallNanos: turn.maxStallNanos,
       stallSite: turn.stallSite, closedAtNanos: turn.closedAtNanos,
       durations: turn.durations, speculationHit: turn.speculationHit)
     let borrowed = Consumer.validateStore(turn: next, index: 2)
     print("LATENCY_CONTRACT unstored_revision=\(next.number) errors=\(borrowed.count)")
     if borrowed.isEmpty { wrong.append("consumer borrowed prior turn's persisted stages") }
   }
'''.replace('VALIDATE', validate)
        main = main.replace('   for issue in wrong', body + '\n   for issue in wrong')
    consumer = 'import Foundation\n@MainActor enum Consumer {\n' + '\n'.join(method(test_source, m) for m in dict.fromkeys(methods)) + '\n}\n'
    if args.full_instrumentation:
        consumer += test_source[test_source.index('enum MainActorStallProbeSelfTest {'):]
    else:
        # validateStore is actor-independent but defined in the production MainActor enum.
        main = main.replace(' static func main() {', ' @MainActor static func main() {')
    for name, value in [('Stubs.swift',stubs+(checked if args.checked_lock else '')), ('Consumer.swift', consumer), ('Driver.swift', main)]:
        target=scratch/name; target.write_text(value); files.append(str(target))
    command = ['xcrun','swiftc','-swift-version','6','-parse-as-library','-module-cache-path',str(scratch/'modulecache'),*files,'-o',str(scratch/'driver')]
    compiled = subprocess.run(command,capture_output=True,text=True)
    (args.output/'compile.log').write_text(compiled.stdout+compiled.stderr)
    print('compile_exit='+str(compiled.returncode))
    if compiled.returncode: raise SystemExit(compiled.returncode)
    result=subprocess.run([str(scratch/'driver')],capture_output=True,text=True)
    (args.output/'run.log').write_text(result.stdout+result.stderr)
    print(result.stdout+result.stderr,end='')
    print('run_exit='+str(result.returncode))
    raise SystemExit(result.returncode)
