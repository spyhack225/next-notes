"""Actual serial parent failure cleanup; no model or native app is loaded."""
import json,subprocess,sys,tempfile,unittest
from pathlib import Path

PARENT_SCRIPT=Path(__file__).with_name("asr_app_compare.py")

class AppParentTests(unittest.TestCase):
 def test_failed_child_joins_and_removes_http_and_marked_model_roots(self):
  with tempfile.TemporaryDirectory() as folder:
   folder=Path(folder);fake=folder/'fake-app';output=folder/'report'
   fake.write_text('#!'+sys.executable+'\n'+'''import os,sys,uuid,tempfile
from pathlib import Path
p=Path.home()/'Library/Caches/NextNotesASRBench'/('app-parent-test-'+uuid.uuid4().hex)
p.mkdir();(p/'.pid').write_text(str(os.getpid()));(p/'partial-weights').write_bytes(b'x'*1024)
http=Path(os.environ.get('TMPDIR',tempfile.gettempdir()))/('asr-parent-test-'+uuid.uuid4().hex)
http.write_bytes(b'x'*1024)
(Path(__file__).parent/'http-target').write_text(str(http))
raise SystemExit(7)
''');fake.chmod(0o755)
   parent=PARENT_SCRIPT
   child=subprocess.run([sys.executable,'-B',str(parent),'--app',str(fake),'--output',str(output),'--models','phonon'],capture_output=True,text=True)
   target=folder/'http-target'
   try:
    self.assertNotEqual(child.returncode,0)
    row=json.loads((output/'runner.json').read_text())[0]
    self.assertEqual(row['exit'],7)
    self.assertTrue(row['childJoined'])
    self.assertTrue(target.exists())
    self.assertFalse(Path(target.read_text()).exists(),"failed app left its HTTP download outside owned cleanup")
    self.assertTrue(row.get('httpTemporaryDeleted',False))
    self.assertEqual(len(row['ownedFailureRootsDeleted']),1)
    self.assertTrue(all(not Path(p).exists() for p in row['ownedFailureRootsDeleted']))
   finally:
    if target.exists():
     owned=Path(target.read_text())
     if owned.name.startswith('asr-parent-test-'):owned.unlink(missing_ok=True)
if __name__=='__main__':unittest.main()
