from pathlib import Path
import sys
root = Path(__file__).resolve().parents[3]
s = (root/'Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift').read_text()
# Owner region only: the sink is separately removed in the next commit.
s = s[:s.index('// MARK: - Backends')]
checks = {'no Apple backing owned by selector': 'AVSpeechBacking()' not in s,
          'no default Apple route': 'backing = systemBacking' not in s,
          'no reply error voice switch': 'fallbackBackingForTesting ?? systemBacking' not in s,
          'Kokoro requires readiness': 'case "kokoro" where KokoroAgentVoice.isSupportedOS && kokoroIsReady:' in s}
for name, passed in checks.items(): print(('PASS' if passed else 'FAIL')+': '+name)
print('VOICE_ROUTES_SOURCE_OK' if all(checks.values()) else 'VOICE_ROUTES_SOURCE_FAILED')
sys.exit(0 if all(checks.values()) else 1)
