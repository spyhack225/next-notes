"""Compile one repaired app primary with SwiftPM's complete original source context.

This is a bounded release repair, not a replacement for the maintained make build.
All other app/SDK objects remain the original optimized build's objects.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import time

report = Path(__file__).resolve().parent
repo = report.parents[2]
product = (Path.home()/'Library/Caches/NextNotesBuild/scratch/release').resolve()
parser = argparse.ArgumentParser()
parser.add_argument('--source',default='Sources/NextNotes/Core/DictationController.swift')
parser.add_argument('--symbol',default='DictationController')
parser.add_argument('--receipt',default='primary-repair')
args = parser.parse_args()
description = json.loads((product/'description.json').read_text())
module = next(x for x in description['swiftCommands'].values() if x['moduleName']=='NextNotes')
source = (repo/args.source).resolve()
assert source.is_relative_to(repo/'Sources/NextNotes') and source.suffix=='.swift'
objects = [Path(x) for x in module['objects'] if x.endswith('/'+source.name+'.o')]
assert len(objects)==1 and str(source) in module['sources']
original_object = objects[0]
work = product.parents[1]/'primary-repair-20261022'/source.stem
work.mkdir(parents=True,exist_ok=True)
driver = [module['executable'],'-module-name','NextNotes','-emit-dependencies','-emit-module',
          '-emit-module-path',module['moduleOutputPath'],'-output-file-map',module['outputFileMapPath'],
          '-I',module['importPath'],'-c',*module['sources'],*module['otherArguments'],'-driver-print-jobs']
plan = subprocess.run(driver,cwd=repo,capture_output=True,text=True,check=True)
jobs = []
for line in plan.stdout.splitlines():
    job = shlex.split(line)
    if job and Path(job[0]).name=='swift-frontend' and '-c' in job:
        if any(job[i]=='-primary-file' and job[i+1]==str(source) for i in range(len(job)-1)):
            jobs.append(job)
assert len(jobs)==1, 'Expected one planned primary batch'
original_job = jobs[0]
remove_pairs = {'-o','-index-unit-output-path','-serialize-diagnostics-path',
                '-emit-reference-dependencies-path','-emit-dependencies-path',
                '-supplementary-output-file-map','-output-file-map'}
command = []
i = 0
while i < len(original_job):
    value = original_job[i]
    if value=='-primary-file':
        i+=2
    elif value in remove_pairs:
        i+=2
    elif value=='-filelist':
        i+=2
    elif value in module['sources']:
        i+=1
    else:
        command.append(value); i+=1
for path in module['sources']:
    if path==str(source): command.append('-primary-file')
    command.append(path)
output = work/(source.name+'.o')
command += ['-o',str(output)]
assert command.count('-primary-file')==1
(work/'planned-primary.json').write_text(json.dumps(command,indent=2)+'\n')
missing = [path for path in module['sources'] if path not in command]
if missing:
    print(dict(missing_source_count=len(missing),first_missing=missing[:3],
               filelist_options=[(command[i],command[i+1]) for i in range(len(command)-1) if 'filelist' in command[i]]),flush=True)
assert all(path in command for path in module['sources'])
assert sum(command.count(path) for path in module['sources'])==len(module['sources'])
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def symbols(path):
    text = subprocess.check_output(['nm','-gU',str(path)],text=True)
    return {line.split()[-1] for line in text.splitlines() if line.split() and args.symbol in line.split()[-1]}
source_hash = digest(source)
old_hash = digest(original_object)
shutil.copyfile(original_object,work/('original-'+source.name+'.o'))
(work/'command.json').write_text(json.dumps(command,indent=2)+'\n')
started = time.monotonic()
with (report/(args.receipt+'-compile.log')).open('w') as log:
    result = subprocess.run(command,cwd=repo,stdout=log,stderr=log)
old_symbols = symbols(original_object)
new_symbols = symbols(output) if result.returncode==0 else set()
receipt = dict(exit=result.returncode,seconds=time.monotonic()-started,
               source_revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
               source_sha256=source_hash,source_unchanged=digest(source)==source_hash,
               full_source_context=len(module['sources']),original_object_sha256=old_hash,
               fixed_object_sha256=digest(output) if output.exists() else None,
               controller_global_symbols_equal=old_symbols==new_symbols,
               primary_source=args.source,symbol_scope=args.symbol,
               original_symbol_count=len(old_symbols),fixed_symbol_count=len(new_symbols),
               missing_symbols=sorted(old_symbols-new_symbols),added_symbols=sorted(new_symbols-old_symbols),
               compiler_command_sha256=hashlib.sha256(json.dumps(command).encode()).hexdigest())
(report/(args.receipt+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt),flush=True)
assert result.returncode==0 and receipt['source_unchanged'] and receipt['controller_global_symbols_equal']
output.replace(original_object)
