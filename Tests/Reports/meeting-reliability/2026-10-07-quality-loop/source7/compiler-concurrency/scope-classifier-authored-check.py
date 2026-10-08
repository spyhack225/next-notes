"""Exact original driver's AST if-phase clause vs draft fixed classifier, no OS children."""
import ast, hashlib, json
from pathlib import Path
from MeetingCompilerFrontendScope import classify_frontend
root=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild')
original=root/'meeting-seventh-release-compiler4-guarded.py';raw=original.read_bytes();tree=ast.parse(raw)
node=next(n for n in ast.walk(tree) if isinstance(n,ast.If) and ast.unparse(n.test)=="phase == 'compile'")
code=compile(ast.fix_missing_locations(ast.Module(body=[node],type_ignores=[])),str(original),'exec')
fixtures=[('dependency-no-count','NextNotesDictionary',[],123,True,False),('dependency-count8','FluidAudio',['8'],123,True,False),('main-one','NextNotes',['1'],123,True,True),('main-eight','NextNotes',['8'],123,False,False),('main-missing','NextNotes',[],123,False,False),('main-duplicate-last1','NextNotes',['8','1'],123,True,True),('main-recycled','NextNotes',['1'],999,False,False),('main-unavailable','NextNotes',['1'],None,False,False),('unknown-no-count',None,[],123,True,False)]
rows=[]
for name,module,counts,start,expected_continuation,expected_proof in fixtures:
 command='/toolchain/swift-frontend -frontend -c'
 if module is not None:command+=' -module-name '+module
 for count in counts:command+=' -num-threads '+count
 usage=None if start is None else {'processStart':start}
 env={'phase':'compile','live':[(41,41,{})],'owned':{41:123},'guard':None,'frontendThreadCounts':[],'listing':lambda:[(41,40,40,'S',command)],'usage':lambda _:usage}
 exec(code,env)
 fixed,refusal=classify_frontend(command,123,usage)
 original_pass=(env['guard'] is None)==expected_continuation and (env['frontendThreadCounts']==['1'])==expected_proof
 fixed_pass=(refusal is None)==expected_continuation and fixed['mainThreadProof']==expected_proof
 rows.append({'case':name,'expectedContinue':expected_continuation,'expectedMainProof':expected_proof,'originalPassed':original_pass,'originalGuard':env['guard'],'originalMainProof':env['frontendThreadCounts']==['1'],'fixedPassed':fixed_pass,'fixedRefusal':refusal,'fixedNumericScope':fixed})
report={'scope':'Exact original AST phase clause; diagnostic classifier-only fixed controls. Process listing/usage supplied authored values; no OS/compiler/native/model/App/Source. Actual arm5 integration still root-owned/unlaunched.','originalDriverSHA256':hashlib.sha256(raw).hexdigest(),'fixedHelperSHA256':hashlib.sha256((root/'MeetingCompilerFrontendScope.py').read_bytes()).hexdigest(),'rows':rows,'originalFailures':sum(not r['originalPassed'] for r in rows),'fixedFailures':sum(not r['fixedPassed'] for r in rows),'checks':len(rows)*2}
out=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify/Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/compiler-concurrency')
(out/'scope-classifier-original-fixed.json').write_text(json.dumps(report,indent=2)+'\n')
(out/'scope-classifier-reviewed-helper.py').write_bytes((root/'MeetingCompilerFrontendScope.py').read_bytes())
(out/'scope-classifier-authored-check.py').write_bytes(Path(__file__).read_bytes())
print(json.dumps({k:report[k] for k in ['originalDriverSHA256','fixedHelperSHA256','originalFailures','fixedFailures','checks']}))
assert report['originalFailures']==2 and report['fixedFailures']==0
