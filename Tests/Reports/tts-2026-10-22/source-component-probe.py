"""Compile the exact source consumer/renderer for the original/fixed regression.
No model, owner store or microphone. DSP reference sink and the unused default
Pocket/Settings branch are substituted; actual output graph, rings, conversion,
source generation, pause/resume, receipts and stop remain native production code.
The full-app flag runs the same authored regression after integration.
"""
import hashlib, json, pathlib, subprocess, sys, tempfile
repo = pathlib.Path(__file__).resolve().parents[3]
speech = repo / 'Sources/NextNotes/Agent/Speech'
scratch = pathlib.Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/scratch/arm64-apple-macosx/release')
phase = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='nextnotes-tts-source-') as directory:
    root = pathlib.Path(directory)
    benchmark = (speech / 'TTSFirstAudioBenchmark.swift').read_text()
    contract = benchmark.split('    private static func sourceContract() async -> [String] {', 1)[1].split('    /// Exercise each new provider', 1)[0]
    contract = '    static func run() async -> [String] {' + contract
    protocol = (speech / 'AgentSpeechSynthesizer.swift').read_text().split('@MainActor\nprotocol AgentSpeechBacking:',1)[1].split('/// Reply-scoped',1)[0]
    protocol = '@MainActor\nprotocol AgentSpeechBacking:' + protocol
    conversion = (repo / 'Sources/NextNotes/Core/AudioConversion.swift').read_text()
    conversion = conversion.split('    /// A 0…1 level for the meters',1)[0]
    original = (repo / 'Sources/NextNotes/Core/AudioConversion.swift').read_text()
    conversion += '    private final class Latch:' + original.split('    private final class Latch:',1)[1]
    fixtures = '''import AVFoundation
import Foundation
import OSLog
''' + protocol + '''
struct AudioChunk: @unchecked Sendable { let buffer: AVAudioPCMBuffer; let captureHostTime: UInt64? }
enum SelfTest {
    static let isRunning = true
    static let requested: String? = "--selftest-tts-source"
    static func diagnostic(_ text: String) { print(text) }
}
enum Log {
    static let agent = Logger(subsystem: "ai.pivotstudio.nextnotes.tts-probe", category: "agent")
    static let audio = Logger(subsystem: "ai.pivotstudio.nextnotes.tts-probe", category: "audio")
}
final class AcousticEchoProcessor: @unchecked Sendable {
    static let shared = AcousticEchoProcessor()
    func feedRendered(_ buffer: AVAudioPCMBuffer, renderHostTime: UInt64?, outputPresentationLatency: Double) { }
    func stopPlayback() { }
}
@MainActor final class Settings {
    static let shared = Settings()
    let agentPocketVoice = "alba"
}
@MainActor final class PocketAgentVoice {
    struct Frame: Sendable { let samples: [Float] }
    static let shared = PocketAgentVoice()
    func frames(for text: String, voice: String) async throws -> AsyncThrowingStream<Frame, Error> {
        fatalError("Unreachable: the production source receives injected deterministic PCM")
    }
}
@MainActor enum SourceContractProbe {
''' + contract + '''}
@main struct ProbeMain {
    @MainActor static func main() async {
        let failures = await SourceContractProbe.run()
        print(failures.isEmpty ? "TTS_SOURCE_OK" : "TTS_SOURCE_FAILED: " + failures.joined(separator: "; "))
        exit(failures.isEmpty ? 0 : 1)
    }
}
'''
    (root / 'Fixtures.swift').write_text(fixtures)
    (root / 'AudioConversion.swift').write_text(conversion)
    description = json.loads((scratch / 'description.json').read_text())
    c = next(c for c in description['swiftCommands'].values() if c['moduleName']=='NextNotes')
    # Reuse only the resolved native module/header search paths, not app entry or codegen flags.
    arguments = c['otherArguments']; imports = []; i = 0
    while i < len(arguments):
        if arguments[i] in ('-I','-F','-sdk','-Xcc','-target'):
            imports += arguments[i:i+2]; i += 2
        else: i += 1
    sources = [speech / n for n in ('AgentPCMRenderer.swift','PocketSourceSpeechBacking.swift','RealtimePCMFloatRing.swift','RealtimePCMReferenceRing.swift','TTSOutputProbe.swift')]
    if phase in ('original','pause-only'):
        baseline = subprocess.check_output(['git','show','0dbba940:Sources/NextNotes/Agent/Speech/AgentPCMRenderer.swift'],text=True,cwd=repo)
        if phase == 'pause-only':
            baseline = baseline.replace('volume: Float) async throws {','volume: Float, initiallyPaused: Bool = false) async throws {',1)
            baseline = baseline.replace('            core.requestedToken.store(requested, ordering: .releasing)',
                '            core.paused.store(initiallyPaused, ordering: .releasing)\n            core.requestedToken.store(requested, ordering: .releasing)',1)
        else:
            original_source = subprocess.check_output(['git','show','0dbba940:Sources/NextNotes/Agent/Speech/PocketSourceSpeechBacking.swift'],text=True,cwd=repo)
            (root/'PocketSourceSpeechBacking.swift').write_text(original_source)
            sources[1] = root/'PocketSourceSpeechBacking.swift'
        intermediate = root/'AgentPCMRenderer.swift'
        intermediate.write_text(baseline)
        sources[0] = intermediate
    sources += [root/'Fixtures.swift',root/'AudioConversion.swift']
    command = [c['executable'],'-O','-swift-version','6','-I',c['importPath'],'-L',str(scratch),*imports,*map(str,sources),'-o',str(root/'probe')]
    pins = {str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_relative_to(repo)}
    pins['compiledSource']=hashlib.sha256(sources[1].read_bytes()).hexdigest()
    pins['compiledRenderer']=hashlib.sha256(sources[0].read_bytes()).hexdigest()
    pins['fixture']=hashlib.sha256(fixtures.encode()).hexdigest()
    pins['regressionBody']=hashlib.sha256(contract.encode()).hexdigest()
    pins['conversionSubset']=hashlib.sha256(conversion.encode()).hexdigest()
    (pathlib.Path(__file__).parent / (phase+'-component-pins.json')).write_text(json.dumps(pins,indent=2)+'\n')
    subprocess.run(command,check=True)
    result = subprocess.run([str(root/'probe')],timeout=12)
    sys.exit(result.returncode)
