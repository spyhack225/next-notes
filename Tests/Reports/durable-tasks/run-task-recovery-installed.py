from pathlib import Path
import subprocess,json,os
root=Path(__file__).resolve().parents[3]
os.chdir(root)
out=root/'Tests/Reports/durable-tasks/2026-10-01-p6-04a-1'
rows=[]
for name in ['task-recovery','task-durability','tasks','tool-review','guided','agent-panes','activity','realtime','toolloop-production','voice-session-reducer','voice-duplex-work','store-isolation']:
 cmd=['Scripts/run-selftest.sh','-ApplePersistenceIgnoreState','YES','-NSQuitAlwaysKeepsWindows','NO','--selftest-'+name]
 p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 (out/('installed-final-'+name+'.log')).write_text(p.stdout)
 rows.append({'name':name,'exit':p.returncode})
 (out/'installed-final-summary.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(name,p.returncode,flush=True)
 if p.returncode:raise SystemExit('unexpected failure: '+name)
