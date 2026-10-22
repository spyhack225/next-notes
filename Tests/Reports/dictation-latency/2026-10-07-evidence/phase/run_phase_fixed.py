import pathlib, subprocess, json, os, time, re, hashlib, ctypes, struct, datetime

repo = pathlib.Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
cache = pathlib.Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-sixth-native-20261008')
candidate = json.loads((repo / 'Tests/Reports/meeting-reliability/2026-10-07-quality-loop/sixth-candidate.json').read_text())
binary = pathlib.Path(candidate['app']) / 'Contents/MacOS/NextNotes'
args = ['--selftest-llm-prefix-cache', '--native-parked-cancellation', '--native-phase-observation', '--selftest-timeout', '240']
# This script is prepared only. The launcher must provide the recorded relay
# handoff for exactly this one CPU fixture; no other test or model is admitted.
agreement = os.environ.get('DICTATION_PHASE_RELAY_AGREEMENT')
assert agreement and agreement.isdecimal(), 'explicit CPU-only scope/handoff missing'
assert hashlib.sha256(binary.read_bytes()).hexdigest() == candidate['sha256']
subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', candidate['app']], check=True, capture_output=True)
gate = json.loads(subprocess.check_output(['agent-relay', 'gate', '--max-swap-gb', '9', '--min-free-gb', '6'], text=True))
pressure = subprocess.check_output(['memory_pressure', '-Q'], text=True)
memory_match = re.search(r'free percentage: (\d+)%', pressure)
assert gate.get('ok') and memory_match and int(memory_match[1]) >= 60, 'explicit CPU phase gate refused'

def listing():
    found = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
        row = line.strip().split(None, 1)
        if len(row) == 2 and row[1].startswith(str(binary) + ' '): found[int(row[0])] = row[1]
    return found

assert not listing(), 'candidate already active; exact ownership unavailable'
def pins():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for root in ['Sources', 'Resources'] for p in sorted((repo / root).rglob('*')) if p.is_file()}

before = pins()
(cache / 'phase-fixed-source-pins-before.json').write_text(json.dumps(before, indent=2) + '\n')
admission = {'atUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'relayAgreementCursor': agreement,
             'gate': gate, 'reportedFreeMemoryPercent': int(memory_match[1]), 'normalGatePassed': False,
             'scope': 'One unchanged private-S1 gpuLayers0 CPU parked-cancel/phase fixture only; no Parakeet, Apple, Metal, physical ASR or full Core benchmark'}
(cache / 'phase-fixed-admission.json').write_text(json.dumps(admission, indent=2) + '\n')
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
began = time.monotonic(); samples = []; identities = {}; guard_reason = None
log = cache / 'phase-fixed.log'
env = {**os.environ, 'NEXTNOTES_APP': candidate['app']}
with (cache / 'phase-fixed-launch.log').open('w') as out:
    launch = subprocess.Popen(['Scripts/run-selftest.sh', '--via-open', '--out', str(log), *args], cwd=repo, env=env, stdout=out, stderr=subprocess.STDOUT)
    while launch.poll() is None:
        for pid, command in listing().items():
            if '--native-phase-observation' not in command: continue
            buf = ctypes.create_string_buffer(1024)
            if lib.proc_pid_rusage(pid, 4, ctypes.byref(buf)) != 0:
                guard_reason = 'exactProcessCountersUnavailable'; continue
            values = struct.unpack_from('10Q', buf.raw, 16)
            if pid in identities and identities[pid] != values[8]:
                guard_reason = 'exactProcessIdentityChanged'; continue
            identities[pid] = values[8]
            samples.append({'elapsed': time.monotonic() - began, 'pid': pid, 'processStart': values[8], 'footprintBytes': values[7], 'residentBytes': values[6]})
            if values[7] > 3_000_000_000: guard_reason = 'exactProcessFootprintAbove3GB'
        swap = subprocess.check_output(['sysctl', 'vm.swapusage'], text=True)
        swap_match = re.search(r'used = ([0-9.]+)M', swap)
        if not swap_match: guard_reason = 'swapCounterUnavailable'
        elif float(swap_match[1]) / 1024 > 9: guard_reason = 'explicitSwapAbove9GB'
        if os.statvfs('/').f_bavail * os.statvfs('/').f_frsize < 6 * 1024**3: guard_reason = 'explicitDiskBelow6GB'
        if time.monotonic() - began > 240: guard_reason = 'elapsedAbove240Seconds'
        if guard_reason:
            for pid in listing():
                if pid not in identities: continue
                buf = ctypes.create_string_buffer(1024)
                if lib.proc_pid_rusage(pid, 4, ctypes.byref(buf)) != 0: continue
                values = struct.unpack_from('10Q', buf.raw, 16)
                if values[8] != identities[pid]: continue
                script = 'ObjC.import("AppKit");var app=$.NSRunningApplication.runningApplicationWithProcessIdentifier(' + str(pid) + ');app.isNil()?false:app.terminate;'
                subprocess.run(['osascript', '-l', 'JavaScript', '-e', script], check=True, timeout=10, capture_output=True)
            launch.wait(timeout=30) # No signal kill; retain ownership if native drain fails.
            break
        try: launch.wait(timeout=.25)
        except subprocess.TimeoutExpired: pass
    code = launch.wait()
assert not listing(), 'native process remains; do not release/handoff or start another test'
after = pins()
(cache / 'phase-fixed-source-pins-after.json').write_text(json.dumps(after, indent=2) + '\n')
receipt = {'atUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'candidateSHA256': candidate['sha256'],
           'args': args, 'exit': code, 'wallSeconds': time.monotonic() - began, 'guardReason': guard_reason,
           'sourceInvariant': before == after, 'sourceCount': len(before), 'ownedIdentities': identities,
           'peakSampledFootprintBytes': max([0] + [s['footprintBytes'] for s in samples]),
           'peakSampledResidentBytes': max([0] + [s['residentBytes'] for s in samples]), 'samples': len(samples),
           'launchJoined': True, 'nativeProcessesJoined': True, 'admission': admission,
           'scope': 'Sampled CPU-only phase/cancellation proof; not owner warm-stall attribution, physical ASR, concurrent voice, quality or complete latency acceptance'}
(cache / 'phase-fixed-memory.json').write_text(json.dumps(samples, indent=2) + '\n')
(cache / 'phase-fixed-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
if log.exists(): print(log.read_text())
raise SystemExit(code if not guard_reason and before == after else 1)
