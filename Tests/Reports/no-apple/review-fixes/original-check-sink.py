from pathlib import Path
import sys
root = Path(__file__).resolve().parents[3]
# Catalog-only UI compatibility shim belongs to the parallel Settings agent.
# Standalone historical Apple benchmark is never linked into NextNotes.
allowed = {'Sources/NextNotes/UI/Settings/ModelsSettingsTab.swift': 'catalog-only legacy Settings screen; replaced by positioning agent', 'Tools/tts_benchmark.swift': 'historical standalone developer benchmark; not linked into app'}
hits = []
for folder in ['Sources', 'Tools']:
    for p in (root/folder).rglob('*.swift'):
        if str(p.relative_to(root)) in allowed: continue
        for number,line in enumerate(p.read_text().splitlines(),1):
            if any(word in line for word in ['AVSpeechSynthesizer','AVSpeechSynthesisVoice','AVSpeechBacking']): hits.append(f'{p.relative_to(root)}:{number}')
print('forbidden app API references:',len(hits))
for hit in hits: print(hit)
print('VOICE_SINK_SOURCE_FAILED' if hits else 'VOICE_SINK_SOURCE_OK')
sys.exit(bool(hits))
