import subprocess,pathlib,json,time,os,re,ctypes,struct,signal,hashlib,datetime
p=pathlib.Path(__file__).parent
repo=pathlib.Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
def pins(): return {str(f):hashlib.sha256(f.read_bytes()).hexdigest() for r in ['Sources','Resources'] for f in (repo/r).rglob('*') if f.is_file()}
def pressure():
 s=subprocess.check_output(['memory_pressure','-Q'],text=True); m=re.search(r'free percentage: (\d+)%',s); return int(m[1]) if m else -1
def table():
 rows={}
 for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid='],text=True).splitlines():
  try: a,b,c=map(int,line.split()); rows[a]=(b,c)
  except ValueError: pass
 return rows
def info(pid):
 b=ctypes.create_string_buffer(1024)
 if lib.proc_pid_rusage(pid,4,ctypes.byref(b))!=0:return None
 v=struct.unpack_from('10Q',b.raw,16);return {'start':v[8],'foot':v[7],'rss':v[6]}
before=pins(); receipts=[]
provenanceFiles=[p/'DefaultParams.c',pathlib.Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/scratch/artifacts/speechify/LlamaFramework/llama.xcframework/macos-arm64_x86_64')/'llama.framework/Versions/A/Headers/llama.h',pathlib.Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/scratch/artifacts/speechify/LlamaFramework/llama.xcframework/macos-arm64_x86_64')/'llama.framework/Versions/A/llama']
(p/'defaults-provenance.json').write_text(json.dumps({str(f):{'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'bytes':f.stat().st_size} for f in provenanceFiles},indent=2)+'\n')
framework='/Users/sergekadjo/Library/Caches/NextNotesBuild/scratch/artifacts/speechify/LlamaFramework/llama.xcframework/macos-arm64_x86_64'
commands=[('compile-defaults',['xcrun','clang','-O2','-F',framework,'-framework','llama','-Wl,-rpath,'+framework,'DefaultParams.c','-o','defaults-check'],25),('run-defaults',[str(p/'defaults-check')],45)]
for label,args,limit in commands:
 gate=json.loads(subprocess.check_output(['agent-relay','gate','--max-swap-gb','8','--min-free-gb','6.5'],cwd=repo,text=True)); free=pressure()
 assert gate['ok'] and free>=55, 'normal component gate refused'
 owned={}; samples=[]; guard=None; began=time.monotonic()
 with (p/(label+'.log')).open('w') as out:
  proc=subprocess.Popen(args,cwd=p,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  while proc.poll() is None:
   t=table(); descendants={proc.pid}; changed=True
   while changed:
    changed=False
    for pid,(parent,group) in t.items():
     if parent in descendants or group==proc.pid:
      if pid not in descendants:descendants.add(pid);changed=True
   total=0; rss=0
   for pid in descendants:
    data=info(pid)
    if data:
     if pid in owned and owned[pid]!=data['start']:guard='PIDidentitychanged'
     owned[pid]=data['start']; total+=data['foot'];rss+=data['rss']
   samples.append({'seconds':time.monotonic()-began,'pids':sorted(descendants),'footSum':total,'rssSum':rss})
   if total>1000000000:guard='descendantFootAbove1GB'
   if time.monotonic()-began>limit:guard='phaseTimeout'
   swap=subprocess.check_output(['sysctl','vm.swapusage'],text=True); m=re.search(r'used = ([0-9.]+)M',swap)
   if not m or float(m[1])/1024>8:guard='swap8'
   v=os.statvfs('/')
   if v.f_bavail*v.f_frsize<6.5*1024**3:guard='disk6.5'
   if pressure()<50:guard='free50'
   if guard:
    # Terminate only this explicitly owned disposable CLI process group.
    os.killpg(proc.pid,signal.SIGTERM);proc.wait(timeout=5);break
   try:proc.wait(timeout=.1)
   except subprocess.TimeoutExpired:pass
  code=proc.wait()
 remaining=[]
 for pid,start in owned.items():
  current=info(pid)
  if current and current['start']==start:remaining.append(pid)
 receipt={'label':label,'args':args,'gate':gate,'freeStart':free,'wallSeconds':time.monotonic()-began,'exit':code,'guard':guard,'ownedStartIDs':owned,'unjoined':remaining,'samples':samples}
 receipts.append(receipt);(p/'resource-receipt.json').write_text(json.dumps(receipts,indent=2)+'\n')
 print(label,code,receipt['wallSeconds'],'guard',guard,'unjoined',remaining,flush=True)
 if guard or remaining or code!=0:raise SystemExit(1)
after=pins();(p/'source-invariance.json').write_text(json.dumps({'before':before,'after':after,'same':before==after,'count':len(before)},indent=2)+'\n')
assert before==after
print('ALL_CLI_PHASES_JOINED_SOURCE_INVARIANT')
