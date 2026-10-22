import subprocess,pathlib,re,sys,json,hashlib,os,time
root=pathlib.Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
binary=pathlib.Path('/Applications/Next Notes.app/Contents/MacOS/NextNotes')
out=pathlib.Path('/tmp/nextnotes-agent-closure-checks-25-current');out.mkdir(exist_ok=True)
launcher=pathlib.Path('/tmp/nextnotes-settings-constructor-isolation/negative-input-launcher.sh')
results=[]
def native(name,args,negative=False,checks=None):
 log=out/(name+'.log');start=time.monotonic()
 with log.open('w') as f:
  try:r=subprocess.run(args,cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=300);code=r.returncode
  except subprocess.TimeoutExpired:code=124
 text=log.read_text()
 ok=(code!=0 and 'SETTINGS_SHEET_FIXTURE_FAILED:' in text) if negative else (code==0 and 'SETTINGS_SHEET_FIXTURE_OK: 4 ' in text)
 details=checks(text) if checks else {}
 ok=ok and all(details.values())
 row={'case':name,'exit':code,'verdict':'PASS' if ok else 'FAIL','elapsed':round(time.monotonic()-start,3),'checks':details}
 results.append(row);print(json.dumps(row),flush=True)
 (out/'settings-summary.json').write_text(json.dumps(results,indent=2)+'\n')
 return ok
for case in ['directory','folders-directory','gws-directory','formatting','runs','mcp','pairing','library','usage','rotated']:
 def verify(text):
  match=re.search(r'^NEGATIVE_FIXTURE_METADATA=(.+)$',text,re.M)
  if not match:return {'metadata':False}
  path=pathlib.Path(match[1]);lines=path.read_text().splitlines();target=pathlib.Path(lines[4]);capture=pathlib.Path(lines[5])
  sentinel=target/'sentinel.txt';expected=(target/'target-before.sha256').read_text().split()[0]
  return {'sentinelUnchanged':hashlib.sha256(sentinel.read_bytes()).hexdigest()==expected,'directoryEmpty':not any((target/'harmless-directory').iterdir()),'noCapturePayload':not capture.exists() or not any(capture.iterdir())}
 if not native('negative-input-'+case,['bash',str(launcher),str(binary),case],True,verify):sys.exit(1)
for name,extra in [('live-before',['--settings-sheet','unused']),('usage-after',['--usage-report']),('other-before',['--selftest-tasks']),('other-after',['--selftest-memory'])]:
 output=out/('mixed-'+name)
 if name in ['live-before','other-before']:args=[str(binary),*extra,'--selftest-settings-sheet',str(output)]
 else:args=[str(binary),'--selftest-settings-sheet',str(output),*extra]
 if not native('negative-mixed-'+name,args,True,lambda text:{'noOutput':not output.exists()}):sys.exit(1)
for name,width in [('notfinite','nan'),('huge','1e308'),('small','1')]:
 output=out/('width-'+name)
 if not native('negative-width-'+name,[str(binary),'--selftest-settings-sheet',str(output),'--settings-pane','agent','--width',width],True,lambda text:{'noOutput':not output.exists()}):sys.exit(1)
output=out/'png-symlink';output.mkdir();sentinel=out/'png-sentinel.txt';sentinel.write_text('harmless png target\n');before=hashlib.sha256(sentinel.read_bytes()).hexdigest();link=output/'settings-computer-320-standard.png';link.symlink_to(sentinel)
if not native('negative-png-leaf',[str(binary),'--selftest-settings-sheet',str(output),'--settings-pane','computer','--width','320'],True,lambda text:{'sentinelUnchanged':hashlib.sha256(sentinel.read_bytes()).hexdigest()==before,'entryStillSymlink':link.is_symlink(),'noAdditionalPNG':list(output.iterdir())==[link]}):sys.exit(1)
for pane,width in [('computer',320),('formatting',320),('agent',560)]:
 capture=out/(pane+str(width))
 if not native('capture-'+pane+str(width),[str(root/'Scripts/run-selftest.sh'),'--selftest-settings-sheet',str(capture),'--settings-pane',pane,'--width',str(width),'--selftest-timeout','300'],checks=lambda text:{'fourPNG':len(list(capture.glob('*.png')))==4,'constructorExercised':'SETTINGS_SHEET_FIXTURE_CONSTRUCTOR_OK:' in text,'consumerAwaited':'SETTINGS_SHEET_FIXTURE_CONSUMER:' in text}):sys.exit(1)
print('SETTINGS_CHECKS_PASS '+str(len(results)),flush=True)
