"""Synthetic credentials only; never opens the private OAuth client JSON."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

source = Path("Resources/Info.plist")
original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix="google-c-injection-") as folder:
    root = Path(folder).resolve()
    fake = root / "fake.json"
    stage = root / "stage"
    run = stage / "install-42"
    contents = run / "Next Notes.app" / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "MacOS" / "NextNotes").write_bytes(b"synthetic built bundle fixture")
    output = contents / "Info.plist"
    output.write_bytes(source.read_bytes())
    fake.write_text(json.dumps({"installed": {
        "client_id": "fixture.apps.googleusercontent.com", "client_secret": "fixture-only"}}))
    def invoke(target=output):
        return subprocess.run(["make", "--no-print-directory", "google-oauth-plist",
            "GOOGLE_OAUTH_JSON=" + str(fake), "GOOGLE_OAUTH_PLIST=" + str(target),
            "STAGE=" + str(stage), "STAGE_RUN=" + str(run)], capture_output=True)
    old = root / "Makefile.original"
    old.write_bytes(subprocess.check_output(["git", "show", "ddf30b7b:Makefile"]))
    wrong = root / "not-a-bundle.plist"
    wrong.write_bytes(source.read_bytes())
    original = subprocess.run(["make", "-f", str(old), "--no-print-directory", "google-oauth-plist",
        "GOOGLE_OAUTH_JSON=" + str(fake), "GOOGLE_OAUTH_PLIST=" + str(wrong)], capture_output=True)
    assert original.returncode == 0 and plistlib.loads(wrong.read_bytes())["NextNotesGoogleClientID"] == "fixture.apps.googleusercontent.com"
    # Same unrelated synthetic destination: the repaired producer must refuse without change.
    original_bytes = wrong.read_bytes()
    assert invoke(wrong).returncode != 0 and wrong.read_bytes() == original_bytes
    print("INJECTION_DESTINATION_ORIGINAL_RED_FIXED_OK")
    for target in [source, root / "other.plist"]:
        if target != source: target.write_bytes(source.read_bytes())
        before = target.read_bytes()
        denied = invoke(target)
        assert denied.returncode != 0 and target.read_bytes() == before
    # Destination hardlinks and directory symlinks cannot redirect the admitted write.
    output.unlink(); output.hardlink_to(source.resolve())
    denied = invoke()
    assert denied.returncode != 0 and output.read_bytes() == source.read_bytes()
    output.unlink(); output.symlink_to(source.resolve())
    assert invoke().returncode != 0
    output.unlink(); output.write_bytes(source.read_bytes())
    other = root / "other"
    contents.rename(other)
    contents.symlink_to(other, target_is_directory=True)
    assert invoke().returncode != 0
    contents.unlink(); other.rename(contents)
    green = invoke()
    info = plistlib.loads(output.read_bytes())
    assert green.returncode == 0 and not green.stdout and not green.stderr
    assert info["NextNotesGoogleClientID"] == "fixture.apps.googleusercontent.com"
    assert info["NextNotesGoogleClientSecret"] == "fixture-only"
    assert all("NextNotesGoogleClientID" not in row and "NextNotesGoogleClientSecret" not in row for row in info["CFBundleURLTypes"])
    output.write_bytes(source.read_bytes()); fake.write_text("invalid")
    invalid = invoke()
    assert invalid.returncode != 0 and output.read_bytes() == source.read_bytes()
    fake.unlink(); missing = invoke()
    assert missing.returncode == 0 and output.read_bytes() == source.read_bytes()
assert original_hash == hashlib.sha256(source.read_bytes()).hexdigest()
print("GOOGLE_OAUTH_INJECTION_OK")
