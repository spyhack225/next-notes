#!/usr/bin/env python3
"""Run only inside heavy.sh; one build followed by the requested native batch."""
from pathlib import Path
import subprocess, tempfile, json, re, hashlib, shutil, sys, os
root = Path(__file__).resolve().parents[4]
report = Path(__file__).resolve().parent
scratch = Path.home() / 'Library/Caches/NextNotesBuild/wt-scratch/voice-settings-ui'
work = Path(tempfile.mkdtemp(prefix='NextNotes-voice-settings-ui-round2-'))
results = []

def run(name, args, expected=None):
    with (report / (name + '.log')).open('w') as output:
        try:
            process = subprocess.run(args, cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=1800,
                                     env={**os.environ, "TMPDIR": str(work) + "/"} if expected else None)
            code = process.returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
    text = (report / (name + '.log')).read_text(errors='replace')
    native = work / (name + '.log')
    if native.exists():
        (report / (name + '-selftest.log')).write_bytes(native.read_bytes())
        text += '\n' + native.read_text(errors='replace')
    markers = [line for line in text.splitlines() if expected and line.startswith(expected + '_') and re.search(r'_(OK|FAILED)(:| |$)', line)]
    item = dict(name=name, exit=code, marker=markers[-1] if markers else 'NO_FINAL_MARKER')
    results.append(item)
    (report / 'checks.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(item), flush=True)
    return code == 0 and (expected is None or bool(markers) and '_OK' in markers[-1])

try:
    if not run('webrtc-build', ['make', 'webrtc-audio']): sys.exit(1)
    if not run('build', ['swift', 'build', '-c', 'debug', '-j', '2', '--scratch-path', str(scratch)]): sys.exit(1)
    binary = scratch / 'debug/NextNotes'
    (report / 'build-pin.json').write_text(json.dumps(dict(
        sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        sources={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'Sources').rglob('*') if p.is_file()}
    ), indent=2) + '\n')
    (report / 'built-source.patch').write_text(subprocess.check_output(['git', 'diff'], cwd=root, text=True))
    checks = [('voice-settings','VOICE_SETTINGS', []), ('settings','SETTINGS', []),
              ('ui-strings','UI_STRINGS', []), ('tts','TTS', []),
              ('tts-stream','TTS_TOKEN_STREAM', []), ('tts','VOICE_POLICY_REVIEW', ['--voice-policy-review']),
              ('voice-conversation','VOICE_CONVERSATION', []), ('voice-delivery','VOICE_DELIVERY', []),
              ('voice-scheduling','VOICE_SCHEDULING', []), ('duplex','DUPLEX', []),
              ('concurrent-voice','CONCURRENT_VOICE', []), ('voice-turn-routing','VOICE_TURN_ROUTING', []),
              ('voice-playback-projection','VOICE_PLAYBACK_PROJECTION', []),
              ('voice-playback-resume-receipt','VOICE_PLAYBACK_RESUME_RECEIPT', []),
              ('catch-up','CATCH_UP', []), ('agent-panes','AGENT_PANES', []),
              ('island','ISLAND', []), ('store-isolation','STORE_ISOLATION', [])]
    ok = True
    for flag, marker, extra in checks:
        name = 'voice-policy-review' if extra else flag
        passed = run(name, [str(binary), '--selftest-' + flag, *extra,
                            '--selftest-out', str(work/(name+'.log'))], marker)
        ok = passed and ok
    images = report / 'shots'
    images.mkdir(exist_ok=True)
    ok = run('preview', [str(binary), '--voice-settings-preview', str(images),
                        '--selftest-out', str(work/'preview.log')], 'VOICE_SETTINGS_PREVIEW') and ok
    print('VOICE_SETTINGS_BATCH_FINISHED', flush=True)
    sys.exit(0 if ok else 1)
finally:
    shutil.rmtree(work)
    shutil.rmtree(scratch, ignore_errors=True)
    (report/'cleanup.json').write_text(json.dumps(dict(temporary_path=str(work), temporary_exists=work.exists(),
                                                      scratch=str(scratch), scratch_exists=scratch.exists()))+'\n')
