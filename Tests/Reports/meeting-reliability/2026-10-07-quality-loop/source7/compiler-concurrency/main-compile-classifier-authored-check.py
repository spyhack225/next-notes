import ast, hashlib, json
from pathlib import Path
from MeetingCompilerMainCompileScope import classify_frontend
root=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild');original=root/'meeting-seventh-release-compiler4-guarded.py';raw=original.read_bytes();tree=ast.parse(raw)
node=next(n for n in ast.walk(tree) if isinstance(n,ast.If) and ast.unparse(n.test)=="phase == 'compile'")
code=compile(ast.fix_missing_locations(ast.Module(body=[node],type_ignores=[])),str(original),'exec')
fixtures=[('dependency-no-count','NextNotesDictionary','-c',[],123,True,False),('dependency-count8','FluidAudio','-c',['8'],123,True,False),('main-one','NextNotes','-c',['1'],123,True,True),('main-eight','NextNotes','-c',['8'],123,False,False),('main-missing','NextNotes','-c',[],123,False,False),('main-duplicate-last1','NextNotes','-c',['8','1'],123,True,True),('main-duplicate-last8','NextNotes','-c',['1','8'],123,False,False),('main-recycled','NextNotes','-c',['1'],999,False,False),('main-unavailable','NextNotes','-c',['1'],None,False,False),('unknown-no-count',None,'-c',[],123,True,False),('main-metadata-no-count','NextNotes','-emit-module',[],123,True,False),('main-metadata-count8','NextNotes','-emit-module',['8'],123,True,False),('main-metadata-count1','NextNotes','-emit-module',['1'],123,True,False)]
rows=[]
for name,module,action,counts,start,expected_continuation,expected_proof in fixtures:
 command='/toolchain/swift-frontend -frontend '+action
 if module is not None:command+=' -module-name '+module
 for count in counts:command+=' -num-threads '+count
 usage=None if start is None else {'processStart':start}
 env={'phase':'compile','live':[(41,41,{})],'owned':{41:123},'guard':None,'frontendThreadCounts':[],'listing':lambda:[(41,40,40,'S',command)],'usage':lambda _:usage}
 exec(code,env);fixed,refusal=classify_frontend(command,123,usage)
 original_checks=[(env['guard'] is None)==expected_continuation,(env['frontendThreadCounts']==['1'])==expected_proof]
 fixed_checks=[(refusal is None)==expected_continuation,fixed['mainCompileThreadProof']==expected_proof]
 rows.append({'case':name,'expectedContinue':expected_continuation,'expectedMainCompileProof':expected_proof,'originalChecks':original_checks,'originalGuard':env['guard'],'originalProof':env['frontendThreadCounts']==['1'],'fixedChecks':fixed_checks,'fixedRefusal':refusal,'fixedNumericScope':fixed})
report={'scope':'Exact original compiler4 AST phase clause vs draft fixed helper; only authored command/start/usage. No OS children/fullcompile/model/App/Source. Main-compile means literal -module-nameNextNotes and -c; all other frontends still retain external resource guard.','originalDriverSHA256':hashlib.sha256(raw).hexdigest(),'fixedHelperSHA256':hashlib.sha256((root/'MeetingCompilerMainCompileScope.py').read_bytes()).hexdigest(),'rows':rows,'originalFailures':sum(not c for r in rows for c in r['originalChecks']),'fixedFailures':sum(not c for r in rows for c in r['fixedChecks']),'checksEach':len(rows)*2}
out=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify/Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/compiler-concurrency')
(out/'main-compile-classifier-original-fixed.json').write_text(json.dumps(report,indent=2)+'\n');(out/'main-compile-classifier-reviewed-helper.py').write_bytes((root/'MeetingCompilerMainCompileScope.py').read_bytes());(out/'main-compile-classifier-authored-check.py').write_bytes(Path(__file__).read_bytes())
print(json.dumps({k:report[k] for k in ['originalDriverSHA256','fixedHelperSHA256','originalFailures','fixedFailures','checksEach']}))
assert report['originalFailures']==6 and report['fixedFailures']==0
