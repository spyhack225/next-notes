"""Owned cache-only exact native6 admission and Mach-O controls; no OS children."""
from pathlib import Path
import ast, hashlib, importlib.util, json, shutil, struct, tempfile
CACHE=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild')
REPORT=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify/Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7/compiler-concurrency')
driver=CACHE/'meeting-seventh-release-native6-guarded.py'; helper=CACHE/'MeetingMachOTextIdentity.py'
assert hashlib.sha256(driver.read_bytes()).hexdigest()=='26b4fe58b1147677c69f53d72ebe1aa9301035b17740abe201ccf7c3ebe3f80e'
assert hashlib.sha256(helper.read_bytes()).hexdigest()=='99dd0d7752aede30f4a33a0698e874245a9b362e6dda919a478be93713ecf947'
spec=importlib.util.spec_from_file_location('owned_macho',helper);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
tree=ast.parse(driver.read_text())
node=next(n for n in ast.walk(tree) if isinstance(n,ast.If) and ast.unparse(n.test)=="phase == 'bundle'")
file_sha_node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='file_sha')
code=compile(ast.fix_missing_locations(ast.Module(body=[file_sha_node,node],type_ignores=[])),'exact-native6-bundle-admission','exec')

def fixture(payload=b'\xc0\x03\x5f\xd6',uuid=bytes(range(16)),flags=0):
 offset=32+152+24
 section=struct.pack('<16s16sQQ8I',b'__text',b'__TEXT',0x100000000+offset,len(payload),offset,2,0,0,0,0,0,0)
 segment=struct.pack('<II16s4QiiII',0x19,152,b'__TEXT',0x100000000,4096,0,offset+len(payload),5,5,1,0)+section
 command=struct.pack('<II16s',0x1b,24,uuid)
 return struct.pack('<8I',0xfeedfacf,0x100000c,0,2,2,len(segment+command),flags,0)+segment+command+payload

root=Path(tempfile.mkdtemp(prefix='meeting-native6-artifact-controls-',dir=CACHE));results=[]
try:
 for name,expect in [('correct-native-link',True),('stale-swiftbuild-link',False),('real-release-directory',False),('unknown-product-link',False),('missing-description',False),('missing-framework',False)]:
  scratch=root/name;native=scratch/'arm64-apple-macosx/release';native.mkdir(parents=True)
  (native/'NextNotes').write_bytes(fixture());(native/'description.json').write_text('{}\n');(native/'llama.framework').mkdir();(native/'llama.framework/llama').write_bytes(b'generic-framework')
  rel=scratch/'release'
  if name=='real-release-directory':rel.mkdir()
  elif name=='stale-swiftbuild-link':
   (scratch/'out/Products/Release').mkdir(parents=True);rel.symlink_to(scratch/'out/Products/Release',target_is_directory=True)
  elif name=='unknown-product-link':
   (scratch/'unknown').mkdir();rel.symlink_to(scratch/'unknown',target_is_directory=True)
  else:rel.symlink_to(native,target_is_directory=True)
  if name=='missing-description':(native/'description.json').unlink()
  if name=='missing-framework':(native/'llama.framework/llama').unlink()
  report=scratch/'report';report.mkdir()
  env={'Path':Path,'hashlib':hashlib,'json':json,'phase':'bundle','scratch':scratch,'expectedNativeProducts':native,'nativeProductIdentity':None,'text_identity':mod.text_identity,'r':report}
  accepted=True;error=None
  try:exec(code,env)
  except Exception as e:accepted=False;error=str(e)
  results.append({'name':name,'expectedAccepted':expect,'accepted':accepted,'passed':accepted==expect,'refusal':error,'actualDriverASTExercised':True})
 p=root/'ParserFixture';p.write_bytes(fixture());identity=mod.text_identity(p)
 cases=[('valid-minimal-thin-arm64',fixture(),'same'),('load-header-only-change',fixture(flags=0x200000),'same'),('text-payload-change',fixture(payload=b'\x00\x00\x00\x00'),'different'),('uuid-change',fixture(uuid=b'1'*16),'different'),('truncated-header',b'\0'*16,'refuse'),('invalid-command-length',fixture()[:36]+struct.pack('<I',4)+fixture()[40:],'refuse')]
 # A sparse invalid table proves the fixed cap refuses without allocating/reading it.
 huge=root/'OversizedTable';huge.write_bytes(struct.pack('<8I',0xfeedfacf,0x100000c,0,2,1,2*1024*1024+1,0,0))
 with huge.open('r+b') as f:f.truncate(32+2*1024*1024+1)
 for name,b,expect in cases:
  p.write_bytes(b);error=None
  try:v=mod.text_identity(p);actual='same' if v==identity else 'different'
  except Exception as e:actual='refuse';error=str(e)
  results.append({'name':name,'expected':expect,'actual':actual,'passed':actual==expect,'refusal':error})
 error=None
 try:mod.text_identity(huge);actual='accepted'
 except Exception as e:actual='refuse';error=str(e)
 results.append({'name':'oversized-load-table','expected':'refuse','actual':actual,'passed':actual=='refuse','refusal':error})
 retained=CACHE/'scratch/out/Products/Release/NextNotes'
 retainedIdentity=mod.text_identity(retained)
 with retained.open('rb') as f:head=f.read(32)
 header=struct.unpack('<8I',head)
 observed={'path':str(retained),'fileBytes':retained.stat().st_size,'loadCommandCount':header[4],'loadCommandBytes':header[5],'textSectionCount':len(retainedIdentity['textSections']),'codeSectionBytes':retainedIdentity['textSections']['__text']['bytes'],'identitySHA256':hashlib.sha256(json.dumps(retainedIdentity,sort_keys=True).encode()).hexdigest(),'parsedOnly':True,'executedApp':False}
 results.append({'name':'actual-retained-app-parser','passed':observed['codeSectionBytes']>0})
finally:
 shutil.rmtree(root)
out={'scope':'MODEL_FREE exact cache driver AST bundle admission + pinned helper, authored files/external filesystem paths substituted. No app/frontend/compiler/ASR/model/OS child; retained app parsed read-only. No product acceptance.','driverSHA256':hashlib.sha256(driver.read_bytes()).hexdigest(),'helperSHA256':hashlib.sha256(helper.read_bytes()).hexdigest(),'checks':len(results),'failures':sum(not r['passed'] for r in results),'results':results,'retainedBinary':observed,'ownedFixtureRemoved':not root.exists(),'limits':'Text sections+UUID identity only; not full DATA payload/byte identity. Actual native path/build/install_name_tool/codesign acceptance remains pending.'}
(REPORT/'native6-authored-product-and-macho-checks.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out,indent=2));assert out['failures']==0
