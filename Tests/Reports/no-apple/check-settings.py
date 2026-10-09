from pathlib import Path
import sys
root=Path(__file__).resolve().parents[3]
s=(root/'Sources/NextNotes/Support/Settings.swift').read_text()
ok='agentVoiceEngine = Self.initialAgentVoiceEngine(from: defaults)' in s and 'return stored == "kokoro" ? "kokoro" : "pocket"' in s
print('VOICE_SETTINGS_SOURCE_OK' if ok else 'VOICE_SETTINGS_SOURCE_FAILED')
sys.exit(not ok)
