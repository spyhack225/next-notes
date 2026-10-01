#!/usr/bin/env python3
"""Compile both actual read-only lifecycle getters. No app/playback consumer proof claimed."""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[4]
synth = (root / 'Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift').read_text()
audio = (root / 'Sources/NextNotes/Agent/RealtimeAudioSession.swift').read_text()
def declaration(source, needle):
    start = source.index(needle)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
body = declaration(synth, '    struct VoiceLifecycleSnapshot {') + '\n' + declaration(synth, '    var voiceLifecycleSnapshot:')
mode = sys.argv[1] if len(sys.argv) > 1 else 'green'
if mode == 'rendered-early':
    assert 'rendered: currentClauseRendered' in body
    body = body.replace('rendered: currentClauseRendered', 'rendered: true', 1)
elif mode != 'green':
    raise SystemExit('unknown mutation')
audio_getter = declaration(audio, '    var voiceShadowOutputSnapshot:')
fixture = '''import Foundation
struct ActionOriginContext: Codable, Sendable, Hashable {}
enum AgentBackendKind: String, Codable, Sendable { case local }
@MainActor final class AgentSpeechSynthesizer {
 static let shared = AgentSpeechSynthesizer()
 var outputGeneration: UInt64 = 1
 var currentClause: String? = "Fixture clause"
 var currentClauseRendered = false
 var isPausedForListening = false
''' + body + '''
}
@MainActor final class RealtimeAudioSession {
 private var voiceShadowOutput: (id: OutputID, kind: OutputKind, generation: UInt64)? = (.init(raw: 1), .delivery([]), 1)
 private var voiceShadowOutputAnnounced = true
 private var voiceShadowHeard = false
 private var voiceShadowStreamOpen = false
''' + audio_getter + '''
}
@main struct Main { @MainActor static func main() {
 let audio = RealtimeAudioSession()
 let actual = AgentSpeechSynthesizer.shared.voiceLifecycleSnapshot
 guard actual.hasClause && !actual.rendered && audio.voiceShadowOutputSnapshot?.status == .queued else {
  print("VOICE_OUTPUT_LIFECYCLE_FAILED: independent queued-before-render projection"); exit(1)
 }
 AgentSpeechSynthesizer.shared.currentClauseRendered = true
 guard audio.voiceShadowOutputSnapshot?.status == .playing else {
  print("VOICE_OUTPUT_LIFECYCLE_FAILED: independent rendered projection"); exit(1)
 }
 print("VOICE_OUTPUT_LIFECYCLE_OK")
} }
'''
with tempfile.TemporaryDirectory(prefix='NextNotesVoiceLifecycle-') as tmp:
    source = Path(tmp) / 'LifecycleFixture.swift'
    source.write_text(fixture)
    executable = Path(tmp) / 'lifecycle'
    subprocess.run(['swiftc', '-swift-version', '6', str(root / 'Sources/NextNotes/Agent/Duplex/VoiceContracts.swift'), str(source), '-o', str(executable)], check=True)
    raise SystemExit(subprocess.run([str(executable)]).returncode)
