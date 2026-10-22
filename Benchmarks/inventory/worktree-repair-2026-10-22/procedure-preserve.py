"""Owner-authorized one-off preservation. Writes Git objects, not worktree files/indexes."""
import os,sys,json,subprocess,hashlib,shutil,tarfile,tempfile
from pathlib import Path
ROOT=Path.cwd();TMP=ROOT/'.scratch/worktree-repair-2026-10-22';REPORT=ROOT/'Benchmarks/inventory/worktree-repair-2026-10-22';ENV=dict(os.environ,GIT_OPTIONAL_LOCKS='0');records=[]

def git(args,env=None,data=None):
 p=subprocess.run(['git','-c','gc.auto=0',*args],cwd=ROOT,env=env or ENV,input=data,capture_output=True)
 if p.returncode:raise RuntimeError(p.stderr.decode(errors='replace'))
 return p.stdout

def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  while block:=f.read(262144):h.update(block)
 return h.hexdigest()

def blob_digest(blob):
 p=subprocess.Popen(['git','cat-file','blob',blob],stdout=subprocess.PIPE,cwd=ROOT)
 h=hashlib.sha256()
 while block:=p.stdout.read(262144):h.update(block)
 assert p.wait()==0
 return h.hexdigest()

def preserve(base,name,parent=None,expected=None,include_git_metadata=False):
 base=Path(base);temp_index=TMP/(name+'.index');temp_index.unlink(missing_ok=True)
 env=dict(ENV,GIT_DIR=str(ROOT/'.git'),GIT_WORK_TREE=str(base),GIT_INDEX_FILE=str(temp_index))
 if parent:git(['read-tree',parent],env)
 else:git(['read-tree','--empty'],env)
 git(['add','-A','--','.'],env)
 ignored=expected['ignored'] if expected else [os.fsdecode(x) for x in git(['ls-files','--others','--ignored','--exclude-standard','-z'],env).split(b'\0') if x]
 working_files={}
 if not expected:
  for directory,dirs,files in os.walk(base):
   dirs[:]=[x for x in dirs if x!='.git']
   for leaf in files:
    path=Path(directory)/leaf
    if path.name=='.git':continue
    rel=str(path.relative_to(base))
    working_files[rel]={'type':'symlink','target':os.readlink(path)} if path.is_symlink() else {'type':'file','sha256':sha(path),'bytes':path.stat().st_size}
 validation_files=expected['uncommitted_and_ignored_files'] if expected else working_files
 tar_roots=set()
 for rel in ignored:
  tar_roots.add('.scratch' if rel.startswith('.scratch/') else rel)
 if include_git_metadata and (base/'.git').is_dir():tar_roots.add('.git')
 archive=TMP/(name+'-ignored.tar.gz');tar_members=[]
 if tar_roots:
  with tarfile.open(archive,'w:gz',dereference=False) as tf:
   for rel in sorted(tar_roots):
    p=base/rel
    if p.exists() or p.is_symlink():tf.add(p,arcname=rel,recursive=True)
  # Validate every originally ignored byte/symlink before making its Git blob.
  with tarfile.open(archive,'r:gz') as tf:
   tar_members=tf.getnames()
   if validation_files:
    for rel in ignored:
     item=validation_files[rel]
     if item['type']=='missing':continue
     member=tf.getmember(rel)
     if item['type']=='symlink':assert member.issym() and member.linkname==item['target'],rel
     elif item['type']=='file':
      h=hashlib.sha256();f=tf.extractfile(member)
      while block:=f.read(262144):h.update(block)
      assert h.hexdigest()==item['sha256'],rel
  archive_sha=sha(archive);blob=git(['hash-object','-w',str(archive)]).decode().strip()
  assert blob_digest(blob)==archive_sha
  git(['update-index','--add','--cacheinfo','100644',blob,'.worktree-preservation/ignored.tar.gz'],env)
  archive.unlink()
 else:archive_sha=None;blob=None
 info={'original_path':str(base),'original_head':parent,'name':name,'original_status_hex':expected.get('status_hex') if expected else None,'original_staged_diff_sha256':expected.get('staged_diff_sha256') if expected else None,'ignored_paths':ignored,'ignored_archive_sha256':archive_sha,'ignored_archive_git_blob':blob,'ignored_archive_members':len(tar_members),'status':'preserved WIP, not product acceptance','source_disposition':'Recovery history; canonical runtime files remain authoritative until a separately verified integration.'}
 if expected:
  metadata=Path(expected['metadata'])
  for filename in ('index',):
   if (metadata/filename).is_file():
    obj=git(['hash-object','-w',str(metadata/filename)]).decode().strip();git(['update-index','--add','--cacheinfo','100644',obj,'.worktree-preservation/original-'+filename],env)
  staged=git(['--git-dir='+str(metadata),'--work-tree='+str(base),'diff','--cached','--binary'])
  obj=git(['hash-object','-w','--stdin'],data=staged).decode().strip();git(['update-index','--add','--cacheinfo','100644',obj,'.worktree-preservation/staged.patch'],env)
 content=json.dumps(info,indent=2).encode()+b'\n';obj=git(['hash-object','-w','--stdin'],data=content).decode().strip();git(['update-index','--add','--cacheinfo','100644',obj,'.worktree-preservation/manifest.json'],env)
 tree=git(['write-tree'],env).decode().strip()
 if validation_files:
  ignored_set=set(ignored)
  for rel,item in validation_files.items():
   if rel in ignored_set:continue
   listing=git(['ls-tree',tree,'--',rel]).decode().strip()
   if item['type']=='missing':assert not listing,rel;continue
   assert listing,rel
   mode,kind,obj=listing.split('\t',1)[0].split()
   if item['type']=='file':assert blob_digest(obj)==item['sha256'],rel
   elif item['type']=='symlink':assert git(['cat-file','blob',obj]).decode()==item['target'],rel
 message=(f'Preserve {name} working state before checkout retirement\n\nOwner-requested local consolidation snapshot. Retains tracked/untracked work, original index/staged patch and ignored-file archive where present. No validation, default promotion, source integration or installation is implied. Original path: {base}\n').encode()
 args=['commit-tree',tree]
 if parent:args+=['-p',parent]
 commit=git(args,data=message).decode().strip();ref='refs/consolidation/20261022/'+name;previous=subprocess.run(['git','rev-parse','--verify',ref],cwd=ROOT,capture_output=True,text=True).stdout.strip()
 git(['update-ref',ref,commit,previous or '0'*40])
 result={**info,'snapshot_commit':commit,'snapshot_tree':tree,'temporary_ref':ref,'preservation_checked_paths':len(validation_files),'original_branch':expected.get('branch') if expected else None}
 records[:]=[x for x in records if x['name']!=name]
 records.append(result);(REPORT/'snapshots.json').write_text(json.dumps(records,indent=2)+'\n');temp_index.unlink()
 print(name,commit,flush=True)
 return commit

before=json.loads((TMP/'after-repair.json').read_text())
for t in before:
 preserve(t['worktree'],Path(t['worktree']).name,parent=t['HEAD'],expected=t)
# Empty standalone review repositories and non-Git task folders are independently recoverable.
audit=json.loads((ROOT/'Benchmarks/inventory/worktree-state-2026-10-22.json').read_text())
for item in audit['extra_scratch_repositories']:
 base=Path(item['path']);assert not git(['-C',str(base),'for-each-ref']).strip()
 preserve(base,'scratch-'+base.name,include_git_metadata=True)
for item in audit['non_git_task_folders']:
 base=Path(item['path']);assert not (base/'.git').exists()
 preserve(base,'task-'+base.name)
print('PRESERVATION_OK',len(records),'snapshot commits; original worktree files/indexes unmodified',flush=True)
