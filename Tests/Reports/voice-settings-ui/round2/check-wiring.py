#!/usr/bin/env python3
"""Source contracts for the actual Settings selection/retry consumers; no native load."""
import hashlib, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[4]
revision = sys.argv[1] if len(sys.argv) > 1 else None

def read(name):
    path = 'Sources/NextNotes/' + name
    value = subprocess.check_output(['git', 'show', revision + ':' + path], cwd=root).decode() if revision else (root / path).read_text()
    print(path, hashlib.sha256(value.encode()).hexdigest())
    return value

tab = read('UI/Settings/ModelsSettingsTab.swift')
section_path = 'Sources/NextNotes/UI/Settings/VoiceSettingsSection.swift'
exists = subprocess.run(['git', 'cat-file', '-e', revision + ':' + section_path], cwd=root, stderr=subprocess.DEVNULL).returncode == 0 if revision else (root / section_path).exists()
section = read('UI/Settings/VoiceSettingsSection.swift') if exists else tab
if not exists: print('Legacy Settings section is inside ModelsSettingsTab')
settings = read('Support/Settings.swift')
synth = read('Agent/Speech/AgentSpeechSynthesizer.swift')
checks = {
    'failed state offers plain Retry': 'button: "Retry"' in section,
    'selection uses preference owner and its epoch': 'settings.agentVoiceEngine = engine.rawValue' in section and 'agentVoiceSelectionEpoch &+= 1' in settings,
    'selection and retry capture the current request': section.count('prepareVoice(request: voice.selectedVoiceRequest)') == 2,
    'deferred action refuses a stale selection or recovery': 'guard voice.selectedVoiceRequest == request else { return }' in section,
    'explicit action clears latch through existing preparation owner': 'await voice.prepareSelectedVoice()' in section and 'selectedVoiceFailed = false' in synth.split('func prepareSelectedVoice() async {')[1].split('private var backing')[0],
    'opening Settings does not directly prepare voice models': 'await pocket.prepare()' not in tab and 'await kokoro.prepare()' not in tab,
    'sample follows live availability rather than cached readiness': 'AgentSpeechSynthesizer.shared.availability == .ready' in tab,
    'no Apple tile or preview catalog': all(word not in section + tab for word in ['AVSpeech', 'macOS voices', 'case apple', 'VoiceEngine.apple']),
    'selected failure outranks cached readiness': 'case .failed: return' in section and 'if failed { return .failed }' in read('Agent/Speech/AgentVoiceAvailability.swift'),
}
for name, ok in checks.items():
    print(('PASS' if ok else 'FAIL') + ': ' + name)
failed = sum(not ok for ok in checks.values())
print('VOICE_SETTINGS_WIRING_FAILED: ' + str(failed) if failed else 'VOICE_SETTINGS_WIRING_OK')
sys.exit(bool(failed))
