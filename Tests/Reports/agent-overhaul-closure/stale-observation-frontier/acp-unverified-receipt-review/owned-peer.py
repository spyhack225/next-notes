"""Off-source proposal only; root must copy into an admitted temp fixture before use.

Sibling config.json keys: mode, marker, objective, taskID, taskAttempt, taskLeaseOwner,
database. Modes: accepted / terminal-write-rejected. Current typed ACP attempt is bound.
This peer has not been run through the app and is not original/fixed evidence.
"""
import json
import pathlib
import sqlite3
import sys
import tempfile
import urllib.parse

root = pathlib.Path(__file__).resolve().parent
temporary = pathlib.Path(tempfile.gettempdir()).resolve()
assert root != temporary and temporary in root.parents
assert "Application Support" not in root.parts
sys.stderr = (root / "peer-stderr.txt").open("a", buffering=1)
config = json.loads((root / "config.json").read_text())
mode = config["mode"]
assert mode in ("accepted", "terminal-write-rejected")
marker = config["marker"]
objective = config["objective"]
assert config["taskAttempt"] == 1
assert config["taskLeaseOwner"].isdigit()
database = pathlib.Path(config["database"]).resolve()
assert database.parent == root and database.is_file()
session = "fixture-unverified-receipt"
calls = []
receipt_file = root / "action-receipts.json"
launch_file = root / "launch.json"
prior = json.loads(launch_file.read_text()) if launch_file.exists() else {}
launch_file.write_text(json.dumps({"launchCount": prior.get("launchCount", 0) + 1}))


def primary():
    conn = sqlite3.connect("file:" + urllib.parse.quote(str(database)) + "?mode=ro", uri=True)
    rows = conn.execute("SELECT id,state,durability FROM task").fetchall()
    conn.close()
    assert len(rows) == 1 and rows[0][0] == config["taskID"]
    durability = json.loads(rows[0][2])
    assert rows[0][1] == "running"
    assert durability["attempt"] == config["taskAttempt"]
    assert durability["leaseOwner"] == config["taskLeaseOwner"]
    assert durability["runtimeClass"] == "acpWorker"
    assert durability.get("attemptStartedAt") is not None
    return {"taskID": rows[0][0], "state": rows[0][1], "durability": durability}


def send(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    mid, method = message.get("id"), message.get("method")
    params = message.get("params") or {}
    calls.append(method)
    (root / "calls.json").write_text(json.dumps(calls))
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1, "agentCapabilities": {}}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": session}})
    elif method == "session/prompt":
        assert params["sessionId"] == session
        assert params["prompt"] == [{"type": "text", "text": objective}]
        assert calls == ["initialize", "session/new", "session/prompt"]
        assert receipt_file.resolve().parent == root and receipt_file.is_file()
        fired_bytes = receipt_file.read_bytes()
        receipts = json.loads(fired_bytes)
        assert len(receipts) == 1
        receipt = receipts[0]
        assert receipt["status"] == "fired"
        assert receipt["toolID"] == "mcp.acp_session"
        assert receipt["preparedAction"]["title"] == objective
        assert receipt["preparedAction"]["routing"]["taskID"] == receipt["taskID"]
        assert receipt["taskID"] == config["taskID"]
        assert receipt["taskAttempt"] == config["taskAttempt"]
        assert receipt["taskLeaseOwner"] == config["taskLeaseOwner"]
        assert receipt["events"][-1]["stage"] == "fired"
        (root / "prompt-primary.json").write_text(json.dumps(primary(), sort_keys=True))
        (root / "prompt-fired-snapshot.json").write_bytes(fired_bytes)
        if mode == "terminal-write-rejected":
            receipt_file.rename(root / "retained-fired.json")
            receipt_file.mkdir()
        (root / "prompt-consumed.json").write_text(json.dumps({
            "taskID": receipt["taskID"], "actionID": receipt["actionID"],
            "objective": objective, "sessionID": session, "mode": mode}))
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": session, "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": marker}}}})
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif method == "session/cancel":
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid,
              "error": {"code": -32601, "message": method or "unknown"}})
