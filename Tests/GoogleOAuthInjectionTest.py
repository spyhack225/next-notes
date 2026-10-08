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
    root = Path(folder)
    fake, output, old = root / "fake.json", root / "Info.plist", root / "Makefile.original"
    old.write_bytes(subprocess.check_output(["git", "show", "c6d850c:Makefile"]))
    fake.write_text(json.dumps({"installed": {
        "client_id": "fixture.apps.googleusercontent.com", "client_secret": "fixture-only"}}))
    output.write_bytes(source.read_bytes())
    args = ["--no-print-directory", "google-oauth-plist", "GOOGLE_OAUTH_JSON=" + str(fake),
            "GOOGLE_OAUTH_PLIST=" + str(output)]
    red = subprocess.run(["make", "-f", str(old)] + args, capture_output=True)
    assert red.returncode != 0 and b"No rule to make target" in red.stderr
    print("INJECTION_ORIGINAL_RED")
    green = subprocess.run(["make"] + args, capture_output=True)
    info = plistlib.loads(output.read_bytes())
    assert green.returncode == 0 and not green.stdout and not green.stderr
    assert info["NextNotesGoogleClientID"] == "fixture.apps.googleusercontent.com"
    assert info["NextNotesGoogleClientSecret"] == "fixture-only"
    denied = subprocess.run(["make", "--no-print-directory", "google-oauth-plist",
        "GOOGLE_OAUTH_JSON=" + str(fake), "GOOGLE_OAUTH_PLIST=" + str(source)], capture_output=True)
    assert denied.returncode != 0
    output.write_bytes(source.read_bytes())
    fake.write_text("invalid")
    invalid = subprocess.run(["make"] + args, capture_output=True)
    assert invalid.returncode != 0 and output.read_bytes() == source.read_bytes()
    fake.unlink()
    missing = subprocess.run(["make"] + args, capture_output=True)
    assert missing.returncode == 0 and output.read_bytes() == source.read_bytes()
assert original_hash == hashlib.sha256(source.read_bytes()).hexdigest()
print("GOOGLE_OAUTH_INJECTION_OK")
