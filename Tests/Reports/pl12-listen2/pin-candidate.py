#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess,sys
r=Path('Tests/Reports/pl12-listen2')
app=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/listen2/debug/NextNotes')
files=['Sources/NextNotes/Agent/VoiceConversationCoordinator.swift','Sources/NextNotes/Formatting/LLM/LocalVoiceFrontend.swift','Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift']
fixture=hashlib.sha256(Path('Sources/NextNotes/Formatting/LLM/PrefixCacheSelfTest.swift').read_bytes()).hexdigest()
red=json.loads((r/'prefill-red-pins.json').read_text())
original=subprocess.check_output(['git','show','9e5e510b:Sources/NextNotes/Formatting/LLM/PrefixCacheSelfTest.swift'],text=True)
current=Path('Sources/NextNotes/Formatting/LLM/PrefixCacheSelfTest.swift').read_text()
def original_body(s):
    return s[s.index('    /// Real private native owner:'):s.index('    // MARK: - Part A, pure')]
assert original_body(original)==original_body(current), 'original native prefill assertions changed'
resident=current[current.index('    /// Additive real producer admission:'):current.index('    /// Real private native owner:')]
v={'commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_hashes':{f:hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files},'fixture_sha256':fixture,'original_fixture_body_unchanged':True,'original_fixture_body_sha256':hashlib.sha256(original_body(current).encode()).hexdigest(),'resident_fixture_sha256':hashlib.sha256(resident.encode()).hexdigest(),'binary_sha256':hashlib.sha256(app.read_bytes()).hexdigest(),'binary_uuid':subprocess.check_output(['dwarfdump','--uuid',str(app)],text=True).strip(),'scope':'debug diagnostic routing and partial native prefill; no default/installation change'}
(r/(sys.argv[1] if len(sys.argv)>1 else 'prefill-final-pins.json')).write_text(json.dumps(v,indent=2)+'\n')
print('INTERACTIVE_PREFILL_FIXTURE_INVARIANCE_OK')
