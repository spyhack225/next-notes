#!/usr/bin/env python3
"""Actual speculation methods, coordinator preparation, recorder, log, and strict join.

Native inference/audio/app bootstrap are excluded. The generationForTesting seam
returns scripted deltas; reaching native inference is fatal. The coordinator's
actual prepare method and commit-side correlation expressions are extracted,
while capture identity/context are isolated fixtures. This does not replace the
installed five-turn capture/native-model proof.
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
HERE = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--original', action='store_true')
parser.add_argument('--prepare-only', action='store_true')
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    # Extracted declarations have balanced braces in interpolations/comments.
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


archive = HERE / 'usage-correlation-before'
frontend_path = (archive / 'LocalVoiceFrontend.swift.txt' if args.original else
                 SOURCES / 'Formatting/LLM/LocalVoiceFrontend.swift')
coordinator_path = (archive / 'VoiceConversationCoordinator.swift.txt' if args.original else
                    SOURCES / 'Agent/VoiceConversationCoordinator.swift')
frontend = frontend_path.read_text()
coordinator = coordinator_path.read_text()
test_path = SOURCES / 'Formatting/LLM/LocalVoiceFrontendSpeculationSelfTest.swift'
test = test_path.read_text()
paths = [
    'Support/Usage/UsageLog.swift', 'Support/Usage/UsageRecord.swift',
    'Support/Usage/ModelPassRecorder.swift', 'Core/DictationController.swift',
    'Formatting/LLM/LLMProvider.swift', 'Formatting/LLM/OpenRouterReasoning.swift',
    'Agent/Voice/VoiceLatencySelfTest.swift'
]
source = {path: (SOURCES / path).read_text() for path in paths}
manifest = {
    'mode': 'original' if args.original else 'current',
    'driver_sha256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
    'sources': {str(path.relative_to(ROOT)): digest(value) for path, value in
                [(frontend_path, frontend), (coordinator_path, coordinator), (test_path, test)]},
    'support_sources': {path: digest(value) for path, value in source.items()},
    'scope': 'actual coordinator preparation and commit correlation expressions; actual '
             'frontend speculation/cancel/barrier/stream/buffer methods; actual recorder/log; '
             'unchanged installed usage-join validator and current speculation self-test',
    'boundaries': ['scripted generation at existing generationForTesting seam; native fallback fatal',
                   'fixture capture prospective TurnID and active session; fixture frontend context',
                   'provider identity fixture, no model generation',
                   'unrelated error classifier replaced with .other; never called by cases',
                   'minimal stage/turn projection for the strict join, no latency timing claim',
                   'coordinator preparation is full method; commit is exact source expressions, '
                   'not full handle/respond/capture pipeline']
}
(args.output / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

# Keep the actual actor state plus complete methods that the existing fixture uses.
actor_start = frontend.index('actor LocalVoiceFrontend {')
state_end = frontend.index('    func setSchedulerAcquiredObserverForTesting')
methods = [
    '    func setGenerationForTesting(', '    func clearStagedTurn()',
    '    func speculate(', '    func cancelSpeculation()',
    '    private func serialBarrier()', '    func sealSpeculation(',
    '    func cancelSpeculation(through', '    func stream(',
    '    private static func waitForPriorInference(',
    '    private func traceSpeculation(', '    private static func emitTiming('
]
unshared = declaration(frontend, '    private func unsharedStream(')
testing_branch = declaration(unshared, '        if let generationForTesting {')
prefix_end = unshared.index(testing_branch) + len(testing_branch)
unshared = unshared[:prefix_end] + '\n        fatalError("Native inference is outside this driver.")\n    }'
frontend_copy = ('import Foundation\n' + frontend[actor_start:state_end] +
                 '\n'.join(declaration(frontend, marker) for marker in methods) +
                 '\n' + unshared + '\n}\n' +
                 declaration(frontend, 'enum VoiceTranscriptCanonical {') + '\n' +
                 declaration(frontend, 'private actor SpeculativeVoiceBuffer {') + '\n')

stubs = r'''import Foundation
import os
enum SelfTest {
    static let isRunning = true
    @MainActor static func diagnostic(_ value: String) { print(value) }
}
enum AppIdentity {
    static var applicationSupportDirectory: URL { fatalError("Owner store refused.") }
}
enum Log { static let agent = Logger(subsystem: "UsageCorrelationDriver", category: "agent") }
final class LanguageModelSession: @unchecked Sendable {}
enum LocalVoicePrompt { static let isEnabled = true }
enum LocalVoiceTypedResponse { static let isEnabled = false }
enum LocalVoiceSplitResponse { static let isEnabled = true }
final class VoiceLatencyTimeline: @unchecked Sendable {
    static let shared = VoiceLatencyTimeline()
    func note(_ key: String, _ value: String) {}
}
struct ToolCallTurn: Sendable {}
enum ModelRole: String { case agent, computerUse, coding, meetingNotes }
protocol LLMProvider: Sendable {
    var id: LLMProviderID { get }
    var displayModelName: String { get }
}
struct FoundationModelLLMProvider: LLMProvider {
    let id = LLMProviderID.appleFoundation
    let displayModelName = "Apple Foundation Model"
}
struct TurnID: Equatable { let raw: UInt64 }
@MainActor final class AgentCaptureController {
    static let shared = AgentCaptureController()
    let isSessionActive = true
    let voiceShadowCurrentTurn: TurnID? = TurnID(raw: 1)
}
@MainActor final class VoiceSession {
    static let shared = VoiceSession()
    func beginTurnIfNeeded() -> TurnID { TurnID(raw: 1) }
}
@MainActor final class AgentSession {
    static let shared = AgentSession()
    let sessionID = UUID()
}
enum VoiceMark: Hashable { case frontendFirstToken }
enum LatencySpanID: String { case voiceTranscriptToFirstToken = "voice.transcript_to_first_token" }
struct VoiceClosedTurn {
    let turnID: UUID?
    let marks: [VoiceMark: Int]
    func seconds(_ span: LatencySpanID) -> Double? { nil }
}
struct VoiceStageSpan {
    static let all: [VoiceStageSpan] = []
    let inTurnSummary: Bool
    let span: LatencySpanID
}
'''
stubs += '\n' + declaration(source['Formatting/LLM/LLMProvider.swift'], 'enum LLMProviderID:')
stubs += '\n' + declaration(source['Formatting/LLM/LLMProvider.swift'], 'struct LLMChatMessage:')
stubs += '\n' + declaration(source['Formatting/LLM/OpenRouterReasoning.swift'], 'struct OpenRouterUsage:')
bounded = 'import Foundation\n' + declaration(source['Core/DictationController.swift'], 'private actor RaceGate<')
bounded += '\n' + declaration(source['Core/DictationController.swift'], 'func withBoundedWait<') + '\n'

# Full original/current prepare producer; exact commit correlation consumer block.
reservation = (declaration(coordinator, '    private func reserveUsageTurn(')
               if '    private func reserveUsageTurn(' in coordinator else '')
if reservation:
    commit_id = ('        let identity = shadowTurn ?? VoiceSession.shared.beginTurnIfNeeded()\n' +
                 coordinator[coordinator.index('        let usageTurnID = reserveUsageTurn(for: identity)'):
                             coordinator.index('        voiceShadowTurns[epoch] = identity',
                                               coordinator.index('        let usageTurnID = reserveUsageTurn(for: identity)'))])
else:
    commit_id = '        ' + coordinator[coordinator.index('let usageTurnID = UUID()'):
                                       coordinator.index('\n', coordinator.index('let usageTurnID = UUID()'))] + '\n'
stream_start = coordinator.index('            let stream = await ModelPassRecorder.$correlation.withValue(')
stream_end = coordinator.index('            let progress = VoiceFrontendStreamProgress()', stream_start)
stream_expression = coordinator[stream_start:stream_end]
coordinator_copy = r'''import Foundation
@MainActor final class CoordinatorProducer {
    private static let responseTokenLimit = 64
    private static let systemPrompt = "Use the envelope."
    private var provisionalText = ""
    private var preparationEpoch: UInt64 = 0
    private var preparationTask: Task<Void, Never>?
    private var prospectiveUsageTurn: (voiceTurn: TurnID, turnID: UUID, conversationID: UUID)?
    private var streamForTesting: (@Sendable (String, [LLMChatMessage]) async -> AsyncThrowingStream<String, Error>)?
    private func frontendRequest(_ text: String) -> (messages: [LLMChatMessage], unused: Bool) {
        ([LLMChatMessage(role: .user, content: "Latest user speech:\n" + text)], false)
    }
    func awaitPreparedForDriver() async { await preparationTask?.value }
'''
coordinator_copy += declaration(coordinator, '    func prepareResponseIfUseful(') + '\n' + reservation
coordinator_copy += '\n    func commitForDriver(_ text: String, shadowTurn: TurnID?) async -> (String, UUID) {\n'
coordinator_copy += commit_id
coordinator_copy += ('        let messages = frontendRequest(text).messages\n'
                     '        let commitRevision = preparationEpoch + 1\n')
coordinator_copy += stream_expression
coordinator_copy += r'''
        var answer = ""
        do { for try await delta in stream { answer += delta } }
        catch { return ("", usageTurnID) }
        return (answer, usageTurnID)
    }
}
'''
consumer = ('import Foundation\n@MainActor enum StrictUsageConsumer {\n' +
            declaration(source['Agent/Voice/VoiceLatencySelfTest.swift'],
                        '    private static func validateUsageLog(').replace('private static func', 'static func', 1) +
            '\n    private static func format(_ seconds: Double) -> String { String(format: "%.3f", seconds) }\n}\n')
usage_record = source['Support/Usage/UsageRecord.swift']
classification = declaration(usage_record, '    static func classify(')
usage_record = usage_record.replace(classification,
                                    '    static func classify(_ error: Error) -> UsageErrorClass { .other }')

main = r'''import Foundation
@main struct Driver {
    @MainActor static func main() async {
        let log = UsageLog.shared
        await LocalVoiceFrontend.shared.setGenerationForTesting { _, _, _ in
            let recorder = ModelPassRecorder(feature: .agentVoice, pass: "frontend-answer",
                provider: FoundationModelLLMProvider(),
                ids: ModelPassRecorder.correlation ?? UsageCorrelation(), log: log)
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            continuation.yield("<answer/> A short fixture explanation.")
            continuation.finish()
            recorder.finish(reason: "stop")
            return stream
        }
        let producer = CoordinatorProducer()
        let input = "Please explain a haiku briefly."
        producer.prepareResponseIfUseful(input)
        await producer.awaitPreparedForDriver()
        for _ in 0..<200 {
            if !log.load().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        var wrong: [String] = []
        let beforeCommit = log.load()
        if beforeCommit.count != 1 {
            wrong.append("actual prepared producer did not finish before commit")
        }
        print("USAGE_PRODUCER_BEFORE_COMMIT rows=\(beforeCommit.count) withTurnID=\(beforeCommit.filter { $0.turnID != nil }.count)")
        let (answer, turnID) = await producer.commitForDriver(input,
            shadowTurn: AgentCaptureController.shared.voiceShadowCurrentTurn)
        if answer != "<answer/> A short fixture explanation." {
            wrong.append("actual committed stream did not consume the prepared answer")
        }
        let summary = ModelPassRecorder(feature: .agentVoice, pass: "turn",
            provider: FoundationModelLLMProvider(),
            ids: UsageCorrelation(turnID: turnID, conversationID: AgentSession.shared.sessionID), log: log)
        summary.finish(reason: "stop")
        log.flush()
        wrong += StrictUsageConsumer.validateUsageLog(
            turn: VoiceClosedTurn(turnID: turnID, marks: [.frontendFirstToken: 1]), index: 1)
        let rows = log.load()
        print("USAGE_PRODUCER_JOIN summary=\(rows.filter { $0.pass == "turn" && $0.turnID == turnID }.count) passes=\(rows.filter { $0.pass != "turn" && $0.turnID == turnID }.count)")
        await LocalVoiceFrontend.shared.clearStagedTurn()
        if !(await LocalVoiceFrontendSpeculationSelfTest.run()) {
            wrong.append("existing speculative recorder correlation regression failed")
        }
        for issue in wrong { print("USAGE_CORRELATION_WRONG: \(issue)") }
        print(wrong.isEmpty ? "USAGE_CORRELATION_OK" : "USAGE_CORRELATION_FAILED: \(wrong.count)")
        log.flush()
        try? FileManager.default.removeItem(at: log.directory)
        exit(wrong.isEmpty ? 0 : 1)
    }
}
'''
generated = {
    'Frontend.swift': frontend_copy, 'Coordinator.swift': coordinator_copy,
    'Stubs.swift': stubs, 'BoundedWait.swift': bounded,
    'UsageLog.swift': source['Support/Usage/UsageLog.swift'],
    'UsageRecord.swift': usage_record,
    'ModelPassRecorder.swift': source['Support/Usage/ModelPassRecorder.swift'],
    'ExistingSpeculationSelfTest.swift': test,
    'StrictUsageConsumer.swift': consumer, 'Driver.swift': main
}
generated_dir = args.output / 'generated'
generated_dir.mkdir(exist_ok=True)
for name, value in generated.items():
    (generated_dir / name).write_text(value)
manifest['generated_sha256'] = {name: digest(value) for name, value in generated.items()}
(args.output / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('mode=' + manifest['mode'])
print('prepared_sources=' + str(len(generated)))
if args.prepare_only:
    print('prepare_only=1; compiler not started')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='NextNotesUsageCorrelationDriver-') as scratch:
    scratch = pathlib.Path(scratch)
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
               '-module-cache-path', str(scratch / 'modulecache'),
               *[str(generated_dir / name) for name in generated], '-o', str(scratch / 'driver')]
    compiled = subprocess.run(command, capture_output=True, text=True)
    (args.output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
    print('compile_exit=' + str(compiled.returncode))
    if compiled.returncode:
        raise SystemExit(compiled.returncode)
    run = subprocess.run([str(scratch / 'driver')], capture_output=True, text=True, timeout=45)
    (args.output / 'run.log').write_text(run.stdout + run.stderr)
    print(run.stdout + run.stderr, end='')
    print('run_exit=' + str(run.returncode))
    raise SystemExit(run.returncode)
