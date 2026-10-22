"""Exercise the real Makefile target against disposable synthetic bundle inputs."""
import json
import pathlib
import plistlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='nextnotes-oauth-packaging-') as temporary:
    root = pathlib.Path(temporary).resolve()
    stage = root / 'stage'
    run = stage / 'install-12345'
    contents = run / 'Next Notes.app' / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'MacOS' / 'NextNotes').write_bytes(b'fixture-only')
    target = contents / 'Info.plist'
    source = root / 'synthetic-client.json'
    source.write_text(json.dumps({'installed': {'client_id': 'fixture.apps.googleusercontent.com', 'client_secret': 'synthetic-secret'}}))
    initial = plistlib.dumps({'CFBundleIdentifier': 'example.fixture'})
    target.write_bytes(initial)
    def invoke(**overrides):
        arguments = {'STAGE': stage, 'STAGE_RUN': run, 'GOOGLE_OAUTH_JSON': source, 'GOOGLE_OAUTH_PLIST': target, **overrides}
        return subprocess.run(['make', '--no-print-directory', 'google-oauth-plist', *[f'{k}={v}' for k,v in arguments.items()]], cwd=repo, capture_output=True)
    result = invoke()
    assert result.returncode == 0, result.stderr.decode()
    assert plistlib.loads(target.read_bytes())['NextNotesGoogleClientID'] == 'fixture.apps.googleusercontent.com'
    assert b'synthetic-secret' not in result.stdout + result.stderr
    assert source.exists()
    target.write_bytes(initial)
    result = invoke(GOOGLE_OAUTH_JSON=root / 'absent.json')
    assert result.returncode == 0 and target.read_bytes() == initial
    outside = root / 'outside.plist'
    outside.write_bytes(initial)
    assert invoke(GOOGLE_OAUTH_PLIST=outside).returncode != 0
    assert outside.read_bytes() == initial
    target.unlink()
    target.symlink_to(outside)
    assert invoke().returncode != 0 and outside.read_bytes() == initial
    target.unlink()
    target.hardlink_to(outside)
    assert invoke().returncode != 0 and outside.read_bytes() == initial
    target.unlink()
    target.write_bytes(initial)
    source.write_text('{}')
    assert invoke().returncode != 0 and target.read_bytes() == initial
    (contents / 'MacOS' / 'NextNotes').unlink()
    assert invoke().returncode != 0 and target.read_bytes() == initial
    print('GOOGLE_OAUTH_PACKAGING_OK: valid injection, absent config, outside target, symlink, hardlink, malformed config, missing executable; synthetic credentials only')
