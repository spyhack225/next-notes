import ctypes, datetime, hashlib, json, os, pathlib, signal, subprocess, time, uuid
report = pathlib.Path(__file__).resolve().parent
candidate = json.loads((report / "coverage-candidate.json").read_text())
source = pathlib.Path(candidate["path"])
target = pathlib.Path("/Applications/Next Notes.app")
owner_pid = 20456
old_hash = "a00ac67934f9357c708c2c17f32ee685ee87734ff72471ed14232b4f1ba95046"
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
def path(pid):
    b = ctypes.create_string_buffer(4096)
    return os.fsdecode(b.value) if lib.proc_pidpath(pid, b, len(b)) > 0 else None
def binary(bundle): return bundle / "Contents/MacOS/NextNotes"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
assert path(owner_pid) == str(binary(target))
assert sha(binary(target)) == old_hash
assert sha(binary(source)) == candidate["binary_sha256"]
meetings = pathlib.Path.home() / "Library/Application Support/Next Notes/Meetings"
for p in meetings.glob("*/meeting.json"):
    status = json.loads(p.read_text()).get("status", {})
    state = status.get("state") if isinstance(status, dict) else status
    assert state not in {"recording", "transcribing", "summarizing"}, "An active meeting must finish first"
owned_meeting = meetings / "3B92EA32-9D55-4622-A2D6-810B044792FF"
before = {p.name:sha(p) for p in owned_meeting.iterdir() if p.is_file()}
token = uuid.uuid4().hex
staged = pathlib.Path("/Applications/Next Notes.app.verified-" + token)
retained = pathlib.Path.home() / "Library/Caches/NextNotesBuild" / ("meeting-quality-rollback-" + token)
retained.mkdir()
rollback = retained / "Next Notes.app"
assert not staged.exists() and not rollback.exists()
subprocess.run(["ditto", str(source), str(staged)], check=True)
assert sha(binary(staged)) == candidate["binary_sha256"]
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged)], check=True)
assert path(owner_pid) == str(binary(target))
os.kill(owner_pid, signal.SIGTERM)
deadline = time.monotonic() + 25
while path(owner_pid) is not None and time.monotonic() < deadline: time.sleep(.1)
assert path(owner_pid) is None, "Graceful quit did not finish; do not launch a second normal app"
target.rename(rollback)
try:
    staged.rename(target)
    assert sha(binary(target)) == candidate["binary_sha256"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(target)], check=True)
except BaseException:
    if not target.exists(): rollback.rename(target)
    raise
private = pathlib.Path.home() / "Library/Application Support/Next Notes/Diagnostics/MeetingQualityReview/3B92EA32-9D55-4622-A2D6-810B044792FF"
with (private / "installed-launch.log").open("w") as output:
    process = subprocess.Popen([str(binary(target))], stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
time.sleep(3)
assert path(process.pid) == str(binary(target))
after = {p.name:sha(p) for p in owned_meeting.iterdir() if p.is_file()}
assert before == after, "Original meeting files changed during installation"
result = {"at":datetime.datetime.now(datetime.timezone.utc).isoformat(), "target":str(target), "source":str(source), "pid":process.pid, "old_pid":owner_pid, "old_pid_exited":True, "binary_sha256":sha(binary(target)), "codesign_verified":True, "matches_tested_candidate":True, "rollback":str(rollback), "rollback_binary_sha256":sha(binary(rollback)), "original_meeting_files_unchanged":True, "mode":"normal owner data; no fixture, provider or preference override", "source_commits":["d729747", "8df94cb"]}
(report / "installed-quality-release.json").write_text(json.dumps(result, indent=2))
print(json.dumps(result), flush=True)
