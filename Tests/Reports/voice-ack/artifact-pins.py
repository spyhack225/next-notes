#!/usr/bin/env python3
# Read-only metadata, run inside the admitted heavy batch after compilation.
import hashlib,json,subprocess,sys
from pathlib import Path
app=Path(sys.argv[1]); report=Path('Tests/Reports/voice-ack')
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 return h.hexdigest()
def command(*args):
 p=subprocess.run(args,capture_output=True,text=True)
 return {'exit':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()}
files={}
root=Path.home()/'.cache/fluidaudio/Models/pocket-tts'
for p in sorted(root.rglob('*')):
 if p.is_file():files[str(p.relative_to(root))]={'bytes':p.stat().st_size,'sha256':digest(p)}
fixture=Path.home()/'Library/Caches/NextNotesBuild/integration/listen-acceptance/fixtures/haiku16k.wav'
d={'revision':command('git','rev-parse','HEAD'),'configuration':sys.argv[2] if len(sys.argv)>2 else 'release -j 2, unbundled executable','binary_sha256':digest(app),'binary_uuid':command('dwarfdump','--uuid',str(app)),'signature':command('codesign','-dv','--verbose=2',str(app)), 'fixture_sha256':digest(fixture),'pocket_precision':'int8','pocket_artifacts':files,'answer_model':'Apple Foundation Models, system-managed artifact not accessible for independent hash','source_sha256':{p:digest(Path(p)) for p in json.loads((report/'green-source-before.json').read_text())}}
(report/'native-artifact-pins.json').write_text(json.dumps(d,indent=2)+'\n')
