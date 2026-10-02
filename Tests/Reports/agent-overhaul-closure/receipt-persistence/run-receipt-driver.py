#!/usr/bin/env python3
"""Prepare or run copied actual receipt producer; no task/attempt/host claims."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

REPORT = pathlib.Path(__file__).resolve().parent
ROOT = REPORT.parents[3]
original = '--original' in sys.argv or '--production-original' in sys.argv
production_original = '--production-original' in sys.argv
prepare_only = '--prepare-only' in sys.argv
mode = 'production-original' if production_original else 'original' if original else 'current'
source_path = REPORT / ('original-ActionRuntime.swift.txt' if original else 'proposed-ActionRuntime.swift.txt')
source = source_path.read_text()
boundary = '/// Shared Judge → Verify → Prepare → Permission → Fire → Verify Result runtime.'
assert source.count(boundary) == 1
producer = source[:source.index(boundary)]
models = (ROOT / 'Sources/NextNotes/Agent/AgentModels.swift').read_text()
risk = models[models.index('enum AgentRisk:'):models.index('enum AgentProposalSource:')]
collaborators = r'''
import Foundation
import OSLog
enum SelfTest { nonisolated(unsafe) static var isRunning = true }
@MainActor enum AppIdentity {
    static var applicationSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesReceiptDeclaredSupport")
}
enum Log { static let agent = Logger(subsystem: "fixture.receipt-persistence", category: "store") }
'''
fixture = r'''
import Foundation
@main struct ReceiptFixture {
    @MainActor static func main() throws {
        let productionOriginal = PRODUCTION_ORIGINAL
        SelfTest.isRunning = !productionOriginal
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesReceiptPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appendingPathComponent("Library/Application Support/Next Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        AppIdentity.applicationSupportDirectory = protected // Declared collaborator, never owner support.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var cases = 0; var failures = 0
        func check(_ value: Bool, _ message: String) {
            cases += 1
            if !value { failures += 1; print("RECEIPT_PERSISTENCE_WRONG: " + message) }
        }
        func receipt(_ id: String) -> ActionReceipt {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            var intent = ActionIntent(source: .agent, authority: .user, verb: "filesystem.read", risk: .read)
            intent.createdAt = date
            var value = ActionReceipt(actionID: UUID(uuidString: id)!, intent: intent, source: .agent,
                authority: .user, toolID: "filesystem.read", taskID: "isolated-task", startedAt: date)
            value.status = .fired
            value.events = [ActionReceiptEvent(id: "isolated-fired", stage: .fired, detail: "fixture", at: date)]
            return value
        }
        let good = receipt("11111111-1111-1111-1111-111111111111")
        let other = receipt("22222222-2222-2222-2222-222222222222")
        func row(_ receipt: ActionReceipt) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: encoder.encode(receipt)) as! [String: Any]
        }
        if !productionOriginal {
            let file = root.appendingPathComponent("fresh.json")
            let store = ActionReceiptStore(fileURL: file)
            check(store.record(good), "safe injected first record returned false")
            check(FileManager.default.fileExists(atPath: file.path), "accepted injected record wrote no disk file")
            check(ActionReceiptStore(fileURL: file).receipt(for: good.actionID) == good,
                "fresh actual reader lost an accepted receipt")
            var completed = good; completed.status = .completed; completed.result = "exact fixture result"
            completed.completedAt = good.startedAt
            check(store.record(completed), "safe injected update returned false")
            check(ActionReceiptStore(fileURL: file).receipt(for: good.actionID) == completed,
                "fresh actual reader lost an accepted lifecycle update")

            let defaultFile = protected.appendingPathComponent("action-receipts.json")
            check(!FileManager.default.fileExists(atPath: defaultFile.path), "declared protected fixture started nonempty")
            check(ActionReceiptStore.shared.record(good) && ActionReceiptStore.shared.receipt(for: good.actionID) == good,
                "default harness in-memory lifecycle stopped working")
            check(!FileManager.default.fileExists(atPath: defaultFile.path), "default harness wrote protected support")

            let rejected = protected.appendingPathComponent("injected.json")
            let retained = try encoder.encode([good]); try retained.write(to: rejected)
            let unsafe = ActionReceiptStore(fileURL: rejected)
            check(unsafe.count == 0, "harness injected support path was read")
            check(!unsafe.record(other) && unsafe.count == 0, "harness injected support record was accepted")
            check(try Data(contentsOf: rejected) == retained, "refused support path bytes changed")
        }

        let mixed = root.appendingPathComponent("mixed.json")
        var broken = try row(other); broken["toolID"] = 42
        let mixedBytes = try JSONSerialization.data(withJSONObject: [row(good), broken])
        try mixedBytes.write(to: mixed)
        let partial = ActionReceiptStore(fileURL: mixed)
        check(partial.count == 1 && partial.receipt(for: good.actionID) == good, "partial reader lost readable exact receipt")
        check(!partial.record(good), "partial decode record falsely accepted persistence")
        check(try Data(contentsOf: mixed) == mixedBytes, "partial decode record erased retained unreadable row bytes")
        check(ActionReceiptStore(fileURL: mixed).count == 1, "partial rejected record lost readable row on reopen")

        for (name, bytes) in [("truncated", Data("[{\"actionID\":\"retained".utf8)), ("wrong-top-level", Data("{\"retained\":true}".utf8))] {
            let file = root.appendingPathComponent(name + ".json"); try bytes.write(to: file)
            let damaged = ActionReceiptStore(fileURL: file)
            check(!damaged.record(good) && damaged.count == 0, "undecodable source accepted replacement: " + name)
            check(try Data(contentsOf: file) == bytes, "undecodable source bytes were erased: " + name)
        }

        let unknown = root.appendingPathComponent("unknown-status.json")
        var odd = try row(other); odd["status"] = "future-stage"
        try JSONSerialization.data(withJSONObject: [row(good), odd]).write(to: unknown)
        let tolerant = ActionReceiptStore(fileURL: unknown)
        check(tolerant.count == 2 && tolerant.receipt(for: other.actionID)?.status == .couldNotVerify,
            "unknown status lost its row or conservative status")
        check(tolerant.record(good), "fully readable unknown-status history was made unwritable")
        check(ActionReceiptStore(fileURL: unknown).count == 2
            && ActionReceiptStore(fileURL: unknown).receipt(for: other.actionID)?.status == .couldNotVerify,
            "unknown-status record lost history on disk reopen")

        if !productionOriginal {
            let failureRoot = root.appendingPathComponent("rejected-save", isDirectory: true)
            try FileManager.default.createDirectory(at: failureRoot, withIntermediateDirectories: false)
            let failureFile = failureRoot.appendingPathComponent("receipts.json")
            let retained = try encoder.encode([good]); try retained.write(to: failureFile)
            let writable = ActionReceiptStore(fileURL: failureFile)
            try FileManager.default.removeItem(at: failureFile)
            try FileManager.default.removeItem(at: failureRoot)
            let blocker = Data("fixture parent is now a file".utf8); try blocker.write(to: failureRoot)
            check(!writable.record(other) && writable.receipts == [good],
                "disk save failure accepted or retained an uncommitted memory receipt")
            check(try Data(contentsOf: failureRoot) == blocker, "failed save changed its retained parent fixture")
        }

        let directory = root.appendingPathComponent("file-is-directory.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let unreadable = ActionReceiptStore(fileURL: directory)
        check(!unreadable.record(good) && unreadable.count == 0, "unreadable source accepted an in-memory replacement")
        check(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "unreadable source directory changed")

        print(failures == 0 ? "RECEIPT_PERSISTENCE_OK: \(cases) cases" : "RECEIPT_PERSISTENCE_FAILED: \(failures) assertions")
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace('PRODUCTION_ORIGINAL', 'true' if production_original else 'false')
generated = {'ActualReceiptProducer.swift': producer, 'ActualRisk.swift': 'import Foundation\n' + risk,
             'Collaborators.swift': collaborators, 'ReceiptFixture.swift': fixture}
inputs = {name: hashlib.sha256(text.encode()).hexdigest() for name, text in generated.items()}
manifest = {'mode': mode, 'full_source_sha256': hashlib.sha256(source.encode()).hexdigest(),
            'actual_risk_source_sha256': hashlib.sha256(models.encode()).hexdigest(), 'inputs': inputs,
            'scope': 'Copied actual store + types; declared SelfTest/AppIdentity/logger. No ActionOrchestrator, owner stores, attempts, task linkage or effect/recovery proof.'}
if prepare_only:
    folder = REPORT / ('prepared-' + mode); folder.mkdir(exist_ok=True)
    for name, text in generated.items(): (folder / name).write_text(text)
    manifest['status'] = 'Prepared only: no compiler or fixture execution'
    (REPORT / (mode + '-prepared-input-manifest.json')).write_text(json.dumps(manifest, indent=2) + '\n')
    print('RECEIPT_DRIVER_PREPARED: ' + mode + '; no compile/run')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='NextNotesReceiptCopied-') as temporary:
    folder = pathlib.Path(temporary)
    for name, text in generated.items(): (folder / name).write_text(text)
    (REPORT / (mode + '-input-manifest.json')).write_text(json.dumps(manifest, indent=2) + '\n')
    binary = folder / 'driver'
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
               *[str(folder / name) for name in generated], '-o', str(binary)]
    compiled = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    print(compiled.stdout + compiled.stderr, end=''); print('compile_exit=' + str(compiled.returncode), flush=True)
    if compiled.returncode: raise SystemExit(compiled.returncode)
    result = subprocess.run([str(binary)], capture_output=True, text=True, cwd=ROOT)
    print(result.stdout + result.stderr, end=''); print('run_exit=' + str(result.returncode), flush=True)
    raise SystemExit(result.returncode)
