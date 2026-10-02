#!/usr/bin/env python3
"""ROOT-brokered artifact mounting/verification. Default commands are read-only.
This agent prepares this driver only; --apply and --root-brokered execute ONLY for root.
No app number selects behavior. Immutable proposal bytes are never changed.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, signal, subprocess, sys, tempfile
from collections import Counter

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parent
ROOT = next(p for p in PACKAGE.parents if (p / 'Package.swift').is_file())
FROZEN_SHA = 'f96aca6a353af31a2d82d55850fde52b9290cfb500bed6c4cce4c7a0161fd5cd'
UI_COMMON_SHA = 'b3702609bc26a48bd2aa68fe73c9cd98026cfcb94a29d0b5a9b6c8d97c3d7f39'
REGISTRY = 'Sources/NextNotes/Agent/Tasks/Durable/TaskWorkerAttemptSelfTest.swift'
ANCHOR = '            try await TaskReceiptObservationSelfTest.originalCases(root: root, input: input, text: text, check: check)\n'
CALL = '            try await TaskArtifactMetadataSelfTest.originalCases(root: root, input: input, text: text, check: check)\n'
FIXTURE = 'Sources/NextNotes/Agent/Tasks/Durable/TaskArtifactMetadataSelfTest.swift'
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()

def immutable():
    assert sha(PACKAGE / 'freeze-manifest.json') == FROZEN_SHA, 'Frozen manifest drift'
    m = json.loads((PACKAGE / 'freeze-manifest.json').read_text())
    for name, digest in m['artifact_sha256'].items():
        assert sha(PACKAGE / name) == digest, ('Frozen artifact drift', name)
    for rel, phases in m['source_sha256'].items():
        for phase, digest in phases.items():
            assert sha(PACKAGE / phase / rel) == digest, ('Frozen snapshot drift', phase, rel)
    assert sha(HERE / 'TaskWorkerAttemptSelfTest.baseline.swift.txt') == m['registry_source_sha256']
    return m

def registry_bytes():
    baseline = (HERE / 'TaskWorkerAttemptSelfTest.baseline.swift.txt').read_text()
    assert baseline.count(ANCHOR) == 1 and CALL not in baseline
    return baseline.replace(ANCHOR, ANCHOR + CALL).encode()

def expected(phase):
    m = immutable()
    key = {'baseline':'baseline', 'original':'original-scaffold', 'fixed':'fixed-proposal'}[phase]
    out = {'Sources/NextNotes/' + rel: hashes[key] for rel, hashes in m['source_sha256'].items()}
    out[REGISTRY] = m['registry_source_sha256'] if phase == 'baseline' else hashlib.sha256(registry_bytes()).hexdigest()
    out[FIXTURE] = None if phase == 'baseline' else m['artifact_sha256']['TaskArtifactMetadataSelfTest.swift.txt']
    return out

def drift(wanted):
    return [{'path': p, 'expected': h, 'actual': sha(ROOT / p) if (ROOT / p).is_file() else None}
            for p, h in wanted.items() if (sha(ROOT / p) if (ROOT / p).is_file() else None) != h]

def source_map():
    files = list((ROOT/'Sources').rglob('*')) + list((ROOT/'Resources').rglob('*'))
    files += [ROOT / n for n in ('Makefile', 'Package.swift', 'Package.resolved')]
    return {str(p.relative_to(ROOT)):sha(p) for p in sorted(files) if p.is_file()}

def bundle_map(bundle):
    return {str(p.relative_to(bundle)):sha(p) for p in sorted(bundle.rglob('*')) if p.is_file()}

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')

def classify(text, phase, stdout=None):
    # Preserve both raw files. Merge only intact event lines, with app log first.
    # A marker interrupting a stdout diagnostic is an observed buffering fragment.
    def events(raw):
        lines = [line for line in raw.splitlines() if re.match(r'^TASK_(?:WORKER_ATTEMPT_(?:WRONG|OK|FAILED)|ARTIFACT_PRODUCER_TRACE):', line)]
        broken = [line for line in lines if len(re.findall(r'TASK_(?:WORKER_ATTEMPT_(?:WRONG|OK|FAILED)|ARTIFACT_PRODUCER_TRACE):', line)) != 1]
        return [line for line in lines if line not in broken], broken
    primary, primary_broken = events(text)
    secondary, secondary_broken = events(stdout or '')
    counts = Counter(primary)
    merged = list(primary)
    seen = Counter()
    for line in secondary:
        seen[line] += 1
        if seen[line] > counts[line]: merged.append(line)
    marker_re = r'^TASK_WORKER_ATTEMPT_(?:OK|FAILED):[^\n]*'
    primary_markers = re.findall(marker_re, '\n'.join(primary), re.M)
    secondary_markers = re.findall(marker_re, '\n'.join(secondary), re.M)
    markers_agree = len(set(primary_markers + secondary_markers)) <= 1
    text = '\n'.join(merged)

    labels = json.loads((HERE/'assertion-classification.json').read_text())
    catalog = labels['label_patterns']
    wrong = re.findall(r'^TASK_WORKER_ATTEMPT_WRONG: (.*)$', text, re.M)
    classified = []
    for value in wrong:
        matches = [p for p in catalog if re.fullmatch(p['regex'], value)]
        category = matches[0]['category'] if len(matches) == 1 else 'unrecognized_or_ambiguous_failure'
        classified.append({'message':value, 'category':category})
    markers = re.findall(r'^TASK_WORKER_ATTEMPT_(?:OK|FAILED):[^\n]*', text, re.M)
    marker = markers[-1] if markers else 'ABSENT'
    traces = re.findall(r'^TASK_ARTIFACT_PRODUCER_TRACE: mode=(\S+) calls=(\d+) joined=(true|false) state=(\S+) values=(-?\d+) kinds=(.*?) retainedRaw=(\d+)$', text, re.M)
    wanted_modes = set(labels['required_modes'])
    trace_ok = len(traces) == 6 and {t[0] for t in traces} == wanted_modes
    trace_ok = trace_ok and all((t[1],t[2]) == (('0','false') if t[0]=='start-rejected' else ('3','true')) for t in traces)
    unexpected = [p for p in classified if p['category'] != 'feature']
    final_count = re.search(r'TASK_WORKER_ATTEMPT_OK: (\d+) cases', marker)
    valid_original = phase=='original' and '_FAILED:' in marker and bool(classified) and not unexpected and trace_ok
    valid_fixed = phase=='fixed' and marker=='TASK_WORKER_ATTEMPT_OK: 1487 cases' and not classified and trace_ok
    failure_number = re.search(r'FAILED: (\d+) assertions', marker)
    failure_count_matches = failure_number is None or int(failure_number[1]) == len(wrong)
    return {'phase':phase, 'marker':marker, 'failures':classified, 'unexpectedFailures':unexpected,
            'modeTraces':traces, 'intactFinalMarkersAgree':markers_agree,
            'streamEvents':{'appLog':len(primary),'stdout':len(secondary),'merged':len(merged)},
            'bufferedFragments':{'appLog':primary_broken,'stdout':secondary_broken}, 'modeControlsComplete':trace_ok, 'failureNumberMatchesLog':failure_count_matches,
            'actualCaseCount':int(final_count[1]) if final_count else None,
            'preparedExpectedChecks':1487, 'preparedNewChecks':135, 'priorBaselineChecks':1352,
            'validOriginalFeatureRED':valid_original and failure_count_matches and markers_agree and not primary_broken,
            'validFixedPASS':valid_fixed and failure_count_matches and markers_agree and not primary_broken,
            'limit':'Failed marker prints assertions, not executed cases;1487 on original is preparation arithmetic only. Prior1352 source calls retained; any prior/control/input/owner failure invalidates RED.'}

def mount(args):
    m = immutable()
    before = 'baseline' if args.phase=='original' else 'original'
    assert not drift(expected(before)), drift(expected(before))
    plan = {'phase':args.phase, 'before':before, 'writes':[], 'willExecute':bool(args.apply)}
    key = 'original-scaffold' if args.phase=='original' else 'fixed-proposal'
    rels = list(m['source_sha256']) if args.phase=='original' else m['fixed_only_source_files']
    payload = {'Sources/NextNotes/'+rel:(PACKAGE/key/rel).read_bytes() for rel in rels}
    if args.phase=='original':
        payload[REGISTRY] = registry_bytes()
        payload[FIXTURE] = (PACKAGE/'TaskArtifactMetadataSelfTest.swift.txt').read_bytes()
    plan['writes'] = [{'path':p, 'sha256':hashlib.sha256(b).hexdigest()} for p,b in payload.items()]
    print(json.dumps(plan, indent=2))
    if not args.apply: return
    assert args.root_brokered and args.preceding_gates_reviewed, 'Root must admit prior106 gates/commit before mounting'
    if args.phase=='original':
        assert args.ui_release_sha == UI_COMMON_SHA, 'Exact current UI release required'
        assert sha(ROOT/'Sources/NextNotes/UI/Agent/AgentWorkingCard.swift') == m['ui_baseline_sha256']
    old = {p:(ROOT/p).read_bytes() if (ROOT/p).exists() else None for p in payload}
    def atomic(path, data):
        fd, name = tempfile.mkstemp(prefix='.artifact-root-mount-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as f: f.write(data)
            os.replace(name, path)
        finally:
            if os.path.exists(name): os.unlink(name)
    try:
        for p,b in payload.items(): atomic(ROOT/p,b)
        assert not drift(expected(args.phase)), drift(expected(args.phase))
    except BaseException:
        for p,b in old.items():
            if b is None: (ROOT/p).unlink(missing_ok=True)
            else: atomic(ROOT/p,b)
        raise

def capture(args):
    assert not drift(expected(args.phase)), drift(expected(args.phase))
    out = Path(args.output).resolve(); out.mkdir(parents=True, exist_ok=False)
    write_json(out/'source-before.json', source_map())
    write_json(out/'artifact-source-before.json', expected(args.phase))
    if args.bundle:
        bundle = Path(args.bundle).resolve()
        write_json(out/'bundle-before.json', bundle_map(bundle))
    write_json(out/'identity.json', {'phase':args.phase, 'buildLabel':args.build_label,
               'bundle':args.bundle, 'freezeSHA':FROZEN_SHA, 'rootScripts':{
               p:sha(ROOT/p) for p in ('Scripts/run-selftest.sh','Scripts/with-install-lock.sh','Scripts/install-bundle.sh','Makefile')}})

def build(args):
    assert args.root_brokered, 'Build/native/install lease belongs to root'
    # Capture full Source BEFORE the existing make/install path, with no tentative app number.
    args.bundle = None
    capture(args)
    out = Path(args.output).resolve()
    before = json.loads((out/'source-before.json').read_text())
    with (out/'build.log').open('w') as stream:
        proc = subprocess.run(['make','install','OPEN=0'], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    after = source_map()
    write_json(out/'source-after-build.json', after)
    record = {'phase':args.phase, 'buildLabel':args.build_label, 'exit':proc.returncode,
              'sourceInvariant':after==before, 'artifactSourceDrift':drift(expected(args.phase))}
    write_json(out/'build-result.json',record);print(json.dumps(record),flush=True)
    assert proc.returncode==0 and record['sourceInvariant'] and not record['artifactSourceDrift'], record
    bundle = Path(args.installed_bundle).resolve()
    binary = bundle/'Contents/MacOS/NextNotes'
    assert binary.is_file()
    identity=json.loads((out/'identity.json').read_text())
    identity.update({'bundle':str(bundle),'installedBinarySHA256':sha(binary)})
    write_json(out/'identity.json',identity);write_json(out/'bundle-before.json',bundle_map(bundle))
    # Retain the exact built executable for review without launching it.
    shutil.copy2(binary,out/'NextNotes-installed-binary')

def run(args):
    assert args.root_brokered, 'Native/build lease belongs to root'
    out = Path(args.capture).resolve(); identity = json.loads((out/'identity.json').read_text())
    assert identity['phase']==args.phase
    before = json.loads((out/'source-before.json').read_text())
    assert source_map()==before and not drift(expected(args.phase)), 'Source drift before native launch'
    bundle = Path(identity['bundle']).resolve()
    bundle_before = json.loads((out/'bundle-before.json').read_text())
    assert bundle_map(bundle)==bundle_before, 'Installed bundle drift before native launch'
    env = os.environ.copy(); env['NEXTNOTES_APP'] = str(bundle)
    results=[]
    for flag in args.flags:
        assert re.fullmatch(r'[a-z0-9-]+',flag), 'Invalid flag'
        assert source_map()==before and bundle_map(bundle)==bundle_before
        app_log=out/(flag+'.log'); stdout=out/(flag+'.stdout')
        assert not app_log.exists() and not stdout.exists(), 'Never overwrite native evidence'
        timed_out=False
        with stdout.open('w') as f:
            proc=subprocess.Popen([str(ROOT/'Scripts/run-selftest.sh'),'--out',str(app_log),'--selftest-'+flag],
                   cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
            try: exit_code=proc.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out=True; os.killpg(proc.pid,signal.SIGTERM)
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid,signal.SIGKILL);proc.wait()
                exit_code=proc.returncode
        text=app_log.read_text() if app_log.exists() else stdout.read_text()
        check=classify(text,args.phase,stdout.read_text() if app_log.exists() else None) if flag=='task-worker-attempt' else {'markers':re.findall(r'^[A-Z][A-Z0-9_]*_(?:OK|FAILED)[^\n]*',text,re.M)}
        check.update({'flag':flag,'exit':exit_code,'timeout':timed_out,'sourceInvariant':source_map()==before,'bundleInvariant':bundle_map(bundle)==bundle_before})
        results.append(check);write_json(out/'native-results.json',results);print(json.dumps(check),flush=True)
        assert not timed_out and check['sourceInvariant'] and check['bundleInvariant'], check
        if flag=='task-worker-attempt':
            assert (exit_code==1 and check['validOriginalFeatureRED']) if args.phase=='original' else (exit_code==0 and check['validFixedPASS']), check
        else: assert exit_code==0 and check['markers'] and '_OK' in check['markers'][-1] and not any('_FAILED' in x for x in check['markers']),check
    write_json(out/'source-after.json',source_map());write_json(out/'bundle-after.json',bundle_map(bundle))

parser=argparse.ArgumentParser(description=__doc__); sub=parser.add_subparsers(dest='command',required=True)
a=sub.add_parser('audit');a.add_argument('--phase',choices=['baseline','original','fixed'],default='baseline')
a=sub.add_parser('mount');a.add_argument('--phase',choices=['original','fixed'],required=True);a.add_argument('--apply',action='store_true');a.add_argument('--root-brokered',action='store_true');a.add_argument('--preceding-gates-reviewed',action='store_true');a.add_argument('--ui-release-sha')
a=sub.add_parser('capture');a.add_argument('--phase',choices=['original','fixed'],required=True);a.add_argument('--output',required=True);a.add_argument('--build-label',required=True);a.add_argument('--bundle')
a=sub.add_parser('build');a.add_argument('--phase',choices=['original','fixed'],required=True);a.add_argument('--root-brokered',action='store_true');a.add_argument('--output',required=True);a.add_argument('--build-label',required=True);a.add_argument('--installed-bundle',default='/Applications/Next Notes.app')
a=sub.add_parser('classify');a.add_argument('--phase',choices=['original','fixed'],required=True);a.add_argument('--log',required=True);a.add_argument('--stdout')
a=sub.add_parser('run-native');a.add_argument('--phase',choices=['original','fixed'],required=True);a.add_argument('--root-brokered',action='store_true');a.add_argument('--capture',required=True);a.add_argument('--timeout',type=int,default=300);a.add_argument('--flags',nargs='+',default=['task-worker-attempt'])
args=parser.parse_args()
if args.command=='audit':
    immutable();d=drift(expected(args.phase));print(json.dumps({'phase':args.phase,'drift':d},indent=2));sys.exit(bool(d))
elif args.command=='mount': mount(args)
elif args.command=='capture': capture(args)
elif args.command=='build': build(args)
elif args.command=='classify': print(json.dumps(classify(Path(args.log).read_text(),args.phase,Path(args.stdout).read_text() if args.stdout else None),indent=2))
elif args.command=='run-native': run(args)
