"""Same actual-process fixture against retained original/fixed lifecycle producer."""
from pathlib import Path
import importlib.util,io,json,subprocess,sys,tempfile,unittest
from unittest.mock import patch
repo=Path(__file__).resolve().parents[3];sys.path.insert(0,str(repo/'Tools'))
spec=importlib.util.spec_from_file_location('reference_tests',repo/'Tools/test_tts_asr_workload.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
original_popen=subprocess.Popen
results={}
with tempfile.TemporaryDirectory(prefix='tts-original-reference-') as temporary:
    old=Path(temporary)/'original.py'
    source=subprocess.check_output(['git','show','2da9a25e:Tools/tts_asr_workload.py'],text=True,cwd=repo)
    old.write_text('import sys\nsys.path.insert(0,'+repr(str(repo/'Tools'))+')\n'+source)
    for variant in ['original','fixed']:
        def spawn(args,**kwargs):
            if variant=='original' and len(args)>1 and str(args[1]).endswith('tts_asr_workload.py'):
                args=[args[0],str(old),*args[2:]]
            return original_popen(args,**kwargs)
        stream=io.StringIO()
        with patch.object(module.subprocess,'Popen',side_effect=spawn):
            suite=unittest.TestSuite([module.WorkloadLifecycle('test_planned_stop_joins_native_worker_before_snapshot_cleanup')])
            result=unittest.TextTestRunner(stream=stream,verbosity=2).run(suite)
        results[variant]={'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'output':stream.getvalue()}
path=Path(__file__).resolve().parent/'reference-original-fixed.json';path.write_text(json.dumps(results,indent=2)+'\n')
assert results['original']['failures']+results['original']['errors']==1
assert results['fixed']['failures']+results['fixed']['errors']==0
print('REFERENCE_CACHE_ORIGINAL_FAILED_FIXED_OK')
