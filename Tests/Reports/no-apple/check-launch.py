from pathlib import Path
import sys
r=Path(__file__).resolve().parents[3]
s=(r/'Sources/NextNotes/NextNotesApp.swift').read_text(); body=s[s.index('    func applicationDidFinishLaunching'):]
needle='AgentSpeechSynthesizer.shared.prepareAtLaunch()'
ok=needle in body and body.index(needle)>body.index('if runRequestedSelfTest() { return }')
print('VOICE_LAUNCH_SOURCE_OK' if ok else 'VOICE_LAUNCH_SOURCE_FAILED')
sys.exit(not ok)
