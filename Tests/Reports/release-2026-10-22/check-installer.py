"""Exercise the real installer with only /Applications redirected to a temp folder.

The old global pkill is intercepted, never executed. Real signing/copying is used.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[3]
old = Path(__file__).with_name('original-install-bundle.sh').read_text()
current = (repo / 'Scripts/install-bundle.sh').read_text()
results = []
with tempfile.TemporaryDirectory(prefix='nextnotes-installer-check-') as temporary:
    root = Path(temporary)
    commands = root / 'commands'
    commands.mkdir()
    mock = commands / 'pkill'
    mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$PKILL_RECEIPT"\n')
    mock.chmod(0o755)
    for label, source in [('original', old), ('fixed', current),
                          ('fixed-invalid', current), ('fixed-active', current)]:
        case = root / label
        apps = case / 'Applications'
        stage = case / 'stage'
        apps.mkdir(parents=True)
        stage.mkdir()
        bundle = stage / 'install-12345' / 'Probe.app'
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        executable = bundle / 'Contents/MacOS/NextNotes'
        shutil.copyfile('/bin/sleep' if label == 'fixed-active' else '/bin/echo', executable)
        executable.chmod(0o755)
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='ai.pivotstudio.nextnotes.installer-probe',
            CFBundleExecutable='NextNotes', CFBundlePackageType='APPL')))
        subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
        installed = apps / 'Probe.app'
        shutil.copytree(bundle, installed)
        (installed / 'old-marker').touch()
        if label == 'fixed-invalid':
            (bundle / 'Contents/Info.plist').write_bytes(b'broken candidate')
        unrelated = stage / 'Another-owned-rollback.app'
        unrelated.mkdir()
        (unrelated / 'keep').touch()
        script = case / 'install.sh'
        script.write_text(source.replace('/Applications/', str(apps) + '/'))
        receipt = case / 'pkill.txt'
        env = dict(os.environ, APPNAME='Probe.app', EXEC='NextNotes', BUNDLE=str(bundle),
                   STAGE=str(stage), OPEN='0', PKILL_RECEIPT=str(receipt),
                   PATH=str(commands) + ':' + os.environ['PATH'])
        active = subprocess.Popen([str(installed / 'Contents/MacOS/NextNotes'), '60']) if label == 'fixed-active' else None
        try:
            run = subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)
            active_survived = active is None or active.poll() is None
        finally:
            if active is not None:
                active.terminate()
                active.wait(timeout=5)
        result = dict(case=label, exit=run.returncode,
                      global_stop_called=receipt.exists(),
                      unrelated_rollback_preserved=(unrelated / 'keep').exists(),
                      old_app_preserved=any((stage / 'rollback').glob('*/Probe.app/old-marker')),
                      candidate_installed=(installed / 'Contents/MacOS/NextNotes').is_file(),
                      own_stage_removed=not bundle.parent.exists())
        results.append(result)
        if label in ('fixed-invalid', 'fixed-active'):
            assert run.returncode != 0
            assert (installed / 'old-marker').exists()
            assert active_survived
            assert (unrelated / 'keep').exists()
            continue
        if label == 'fixed':
            assert run.returncode == 0, run.stderr
            assert not result['global_stop_called']
            assert all(result[k] for k in ['unrelated_rollback_preserved', 'old_app_preserved',
                                           'candidate_installed', 'own_stage_removed'])
    assert results[0]['global_stop_called']
    assert not results[0]['unrelated_rollback_preserved']
    assert not results[0]['old_app_preserved']
path = Path(__file__).with_name('installer-check.json')
path.write_text(json.dumps(results, indent=2) + '\n')
print('INSTALLER_ORIGINAL_FAILED_FIXED_OK')
