from pathlib import Path
import sys
root = Path(__file__).resolve().parents[3]
api = root / 'Sources/NextNotes/Agent/Speech/AgentVoiceAvailability.swift'
synth = (root / 'Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift').read_text()
checks = {'availability API exists': api.exists(), 'existing speech owner exposes availability': 'var availability: AgentVoiceAvailability' in synth}
for name, passed in checks.items():
    print(('PASS' if passed else 'FAIL') + ': ' + name)
print('VOICE_AVAILABILITY_SOURCE_OK' if all(checks.values()) else 'VOICE_AVAILABILITY_SOURCE_FAILED')
sys.exit(0 if all(checks.values()) else 1)
