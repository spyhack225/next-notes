#!/usr/bin/env python3
"""Compile tiny fixtures from the actual coordinator methods; no app build or model."""
from pathlib import Path
import subprocess, tempfile
repo = Path(__file__).resolve().parents[4]
source = (repo / 'Sources/NextNotes/Agent/VoiceConversationCoordinator.swift').read_text()
def method(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
methods = '\n'.join(method(m) for m in [
    '    private func resolveInput(', '    private func resolveClassified(',
    '    func closeSession()', '    func waitForInputResolution()',
    '    func mayCommitEffect()', '    private func barrierIsPending(',
    '    private func resumeResolvedBarrierWaiters()', '    private func cancelBarrierWaiter(',
    '    private func waitForBarrier('])
header = '''import Foundation
@MainActor final class AgentCaptureController {
 static let shared = AgentCaptureController()
 var isSessionActive = true
}
@MainActor final class VoiceConversationCoordinator {
 var inputPending = false { didSet { resumeResolvedBarrierWaiters() } }
 var effectHoldEpoch: UInt64? { didSet { resumeResolvedBarrierWaiters() } }
 private var barrierWaiters: [UUID: (effects: Bool, continuation: CheckedContinuation<Void, Never>)] = [:]
 var count: Int { barrierWaiters.count }
 var inputEpoch: UInt64 = 0
 var responseID = UUID()
 var responseTask: Task<Void, Never>?
 var didPrewarmWorker = false
 var pendingAction: String?
 var clarifiedTexts: Set<String> = []
 func cancelResponsePreparation() {}
 func classified(_ epoch: UInt64) { resolveClassified(epoch: epoch) }
'''
footer = '''}
@main struct Driver {
 @MainActor static func main() async {
  let c = VoiceConversationCoordinator()
  var failed: [String] = []
  func check(_ v: Bool, _ s: String) { if !v { failed.append(s) } }
  func spin(_ predicate: () -> Bool) async {
   for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(1)) }
  }
  c.inputPending = true
  var readDone = false; var effectDone = false; var cancelledResult: Bool?
  let read = Task { @MainActor in await c.waitForInputResolution(); readDone = true }
  let effect = Task { @MainActor in effectDone = await c.mayCommitEffect() }
  let cancelled = Task { @MainActor in cancelledResult = await c.mayCommitEffect() }
  await spin { c.count == 3 }; check(c.count == 3, "registration")
  cancelled.cancel()
  await spin { cancelledResult != nil }; check(cancelledResult == false && c.count == 2, "cancel cleanup")
  c.effectHoldEpoch = 1; c.inputPending = false
  await spin { readDone }; check(readDone && !effectDone && c.count == 1, "failure hold separates reads/effects")
  c.inputEpoch = 3; c.inputPending = true
  c.classified(1)
  check(c.inputPending && c.effectHoldEpoch == 1, "older classification must retain newer input/hold")
  c.classified(3)
  await spin { effectDone }; check(effectDone && c.count == 0, "later classified hold clears")
  c.inputPending = true
  var closedEffect = false; var closedRead = false
  let e = Task { @MainActor in closedEffect = await c.mayCommitEffect() }
  let r = Task { @MainActor in await c.waitForInputResolution(); closedRead = true }
  await spin { c.count == 2 }
  c.closeSession()
  await spin { closedEffect && closedRead }
  check(closedEffect && closedRead && c.count == 0, "session close wakes all")
  for item in failed { print("DUPLEX_BARRIER_WRONG: \\(item)") }
  print(failed.isEmpty ? "DUPLEX_BARRIER_OK" : "DUPLEX_BARRIER_FAILED")
  read.cancel(); effect.cancel(); e.cancel(); r.cancel()
  Foundation.exit(failed.isEmpty ? 0 : 1)
 }
}
'''
mutate = __import__('sys').argv[1] if len(__import__('sys').argv) > 1 else ''
if mutate == 'forget-cancel':
    methods = methods.replace(method('    private func cancelBarrierWaiter('), '    private func cancelBarrierWaiter(_ id: UUID) { }')
if mutate == 'ignore-hold':
    methods = methods.replace('(inputPending || (effects && effectHoldEpoch != nil))', 'inputPending')
with tempfile.TemporaryDirectory(prefix='nextnotes-duplex-barrier-') as tmp:
    tmp = Path(tmp)
    swift = tmp / 'fixture.swift'; swift.write_text(header + methods + footer)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(swift),'-o',str(tmp/'fixture')],check=True)
    raise SystemExit(subprocess.run([str(tmp/'fixture')], timeout=5).returncode)
