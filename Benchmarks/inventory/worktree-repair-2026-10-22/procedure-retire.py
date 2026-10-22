import subprocess,json,os,hashlib,shutil,stat,time
from pathlib import Path
ROOT=Path.cwd();OUT=ROOT/'Benchmarks/inventory/worktree-repair-2026-10-22';TMP=ROOT/'.scratch/worktree-repair-2026-10-22';CACHE=Path.home()/'Library/Caches/NextNotesBuild';ENV=dict(os.environ,GIT_OPTIONAL_LOCKS='0');records=[]
def git(*args):
 p=subprocess.run(['git','-c','gc.auto=0',*args],cwd=ROOT,env=ENV,capture_output=True)
 if p.returncode:raise RuntimeError(p.stderr.decode(errors='replace'))
 return p.stdout

def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  while x:=f.read(262144):h.update(x)
 return h.hexdigest()

def save():
 (OUT/'retirement.json').write_text(json.dumps({'actions':records,'free_before_bytes':free_before,'free_now_bytes':shutil.disk_usage(ROOT).free},indent=2)+'\n')

snapshots=json.loads((OUT/'snapshots.json').read_text());before=json.loads((TMP/'before-retirement.json').read_text());branches=json.loads((OUT/'original-branches.json').read_text());audit=json.loads((ROOT/'Benchmarks/inventory/worktree-state-2026-10-22.json').read_text());free_before=shutil.disk_usage(ROOT).free
roots=[x['original_path'] for x in snapshots];opens=[];rec={}
process=subprocess.run(['lsof','-nP','-Fpcn'],capture_output=True,text=True)
for line in process.stdout.splitlines():
 if line.startswith('p'):rec={'pid':line[1:]}
 elif line.startswith('c'):rec['command']=line[1:]
 elif line.startswith('n'):
  name=line[1:]
  if any(name==p or name.startswith(p+'/') for p in roots):opens.append({**rec,'path':name})
assert not opens,opens
for s in snapshots:git('merge-base','--is-ancestor',s['snapshot_commit'],'HEAD');git('cat-file','-e',s['snapshot_commit']+'^{tree}')
for b in branches:
 if b['branch']=='main':continue
 assert git('rev-parse','refs/heads/'+b['branch']).decode().strip()==b['sha'],b['branch']
 git('merge-base','--is-ancestor',b['sha'],'HEAD')
# Revalidate every original uncommitted/ignored byte immediately before deletion.
for t in before:
 base=Path(t['worktree']);assert base.resolve().is_relative_to(CACHE.resolve()) and base!=ROOT
 status=git('-C',str(base),'status','--porcelain=v1','--untracked-files=all','-z');assert status.hex()==t['status_hex'],str(base)
 for rel,item in t['uncommitted_and_ignored_files'].items():
  p=base/rel
  if item['type']=='missing':assert not p.exists()
  elif item['type']=='symlink':assert p.is_symlink() and os.readlink(p)==item['target']
  elif item['type']=='file':assert p.is_file() and sha(p)==item['sha256'],str(p)
print('RETIREMENT_PREFLIGHT_OK:all31snapshots reachable; no open files; all1342paths identical',flush=True)
for t in before:
 base=Path(t['worktree']);size=int(subprocess.check_output(['du','-sk',str(base)],text=True).split('\t',1)[0])*1024
 git('worktree','remove','--force',str(base));assert not base.exists()
 records.append({'action':'worktree_removed','path':str(base),'du_bytes_before':size,'recovery_commit':next(s['snapshot_commit'] for s in snapshots if s['original_path']==str(base))});save();print('Removed worktree',base.name,flush=True)
for s in snapshots:
 if s['original_path'] in {x['worktree'] for x in before}:continue
 base=Path(s['original_path']);assert base.resolve().is_relative_to((CACHE/'wt').resolve()) and base.is_dir() and not base.is_symlink()
 # Their complete content was independently verified into the snapshot tree/archive.
 shutil.rmtree(base);assert not base.exists()
 records.append({'action':'scratch_task_folder_removed','path':str(base),'recovery_commit':s['snapshot_commit']});save()
for b in branches:
 name=b['branch']
 if name=='main':continue
 git('branch','-d','--',name)
 records.append({'action':'merged_local_branch_deleted','branch':name,'original_tip':b['sha']});save()
for s in snapshots:
 git('update-ref','-d',s['temporary_ref'],s['snapshot_commit'])
# Remove only exact coordinator files already copied and hash checked, never caches.
for item in json.loads((OUT/'coordinator-files.json').read_text()):
 old=Path(item['original']);retained=ROOT/item['retained']
 assert sha(old)==item['sha256']==sha(retained)
 old.unlink();records.append({'action':'coordinator_file_retired','original':str(old),'retained':item['retained']})
for p in (CACHE/'wt',CACHE/'claude-worktrees'):
 if p.is_dir() and not any(p.iterdir()):p.rmdir()
# No stale registration, shared cache or unrelated Git object is removed.
git('worktree','prune','--verbose')
assert git('branch','--format=%(refname:short)').decode().splitlines()==['main']
assert git('worktree','list','--porcelain').decode().count('worktree ')==1
for s in snapshots:git('merge-base','--is-ancestor',s['snapshot_commit'],'HEAD')
source_diff=git('diff','--name-only','8b3d4f8a','HEAD','--','Sources','Package.swift','Package.resolved','Makefile','Resources');assert not source_diff
save();print('RETIREMENT_OK:1branch,1worktree; all31snapshots retained; current application source unchanged',flush=True)
