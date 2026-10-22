"""Read-only before/after witness for the existing voice caches used by this run."""
import hashlib,json,pathlib,sys
report=pathlib.Path(__file__).resolve().parent
base=pathlib.Path.home()/'.cache/fluidaudio/Models'
result={}
for name in ('pocket-tts','kokoro','kokoro-82m-coreml'):
 root=base/name
 for path in sorted(root.rglob('*')):
  if not path.is_file(): continue
  before=path.stat()
  with path.open('rb') as stream: digest=hashlib.file_digest(stream,'sha256').hexdigest()
  after=path.stat()
  if (before.st_ino,before.st_size,before.st_mtime_ns)!=(after.st_ino,after.st_size,after.st_mtime_ns):
   raise RuntimeError('Owner cache changed during read; cannot accept this witness')
  result[str(path.relative_to(base))]={'bytes':after.st_size,'sha256':digest}
phase=sys.argv[1]
(report/('owner-caches-'+phase+'.json')).write_text(json.dumps(result,indent=2)+'\n')
if phase=='after':
 original=json.loads((report/'owner-caches-before.json').read_text())
 changed=[p for p in original if original[p]!=result.get(p)]
 added=sorted(set(result)-set(original))
 verdict={'originalFiles':len(original),'currentFiles':len(result),'changedOrMissing':changed,'added':added,'unchanged':not changed and not added}
 (report/'owner-cache-preservation.json').write_text(json.dumps(verdict,indent=2)+'\n')
 print(json.dumps(verdict))
else: print('Pinned',len(result),'existing files without copying model weights.')
