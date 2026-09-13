import Foundation

/// Local stdio peers so `--selftest-mcp` / `--selftest-acp` can prove a handshake
/// without Claude Code or a cloud MCP. Written to a temp file and launched with
/// `/usr/bin/python3`.
enum AgentStdioFixtures {
    static let python = "/usr/bin/python3"

    static func writeMCP() throws -> URL {
        try write(name: "nextnotes-mcp-fixture.py", contents: mcp)
    }

    static func writeACP() throws -> URL {
        try write(name: "nextnotes-acp-fixture.py", contents: acp)
    }

    private static func write(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static let mcp = """
        #!/usr/bin/env python3
        import json, sys

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            params = msg.get("params") or {}
            if method == "initialize":
                send({
                    "jsonrpc": "2.0",
                    "id": mid,
                    "result": {
                        "protocolVersion": params.get("protocolVersion") or "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "nextnotes-mcp-fixture", "version": "1"},
                        "sessionId": "fixture-mcp",
                    },
                })
            elif method in ("notifications/initialized", "initialized"):
                pass
            elif method == "tools/list":
                send({
                    "jsonrpc": "2.0",
                    "id": mid,
                    "result": {
                        "tools": [{
                            "name": "echo",
                            "description": "Echo text",
                            "annotations": {"readOnlyHint": True, "title": "Echo"},
                        }],
                    },
                })
            elif method == "tools/call":
                args = params.get("arguments") or {}
                text = args.get("text") or args.get("message") or "echo"
                send({
                    "jsonrpc": "2.0",
                    "id": mid,
                    "result": {"content": [{"type": "text", "text": text}]},
                })
            elif mid is not None:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method}})
        """

    static let acp = """
        #!/usr/bin/env python3
        import json, sys

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        session = "fixture-acp"
        waiting_prompt = None

        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            params = msg.get("params") or {}
            if mid == 900 and method is None:
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": "ACP session finished."},
                        },
                    },
                })
                if waiting_prompt is not None:
                    send({"jsonrpc": "2.0", "id": waiting_prompt, "result": {"stopReason": "end_turn"}})
                    waiting_prompt = None
                continue
            if method == "initialize":
                send({
                    "jsonrpc": "2.0",
                    "id": mid,
                    "result": {
                        "protocolVersion": 1,
                        "agentCapabilities": {"loadSession": False},
                        "agentInfo": {"name": "nextnotes-acp-fixture", "version": "1"},
                    },
                })
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": session}})
            elif method == "session/prompt":
                waiting_prompt = mid
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session,
                        "update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "secret chain of thought"}},
                    },
                })
                send({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session,
                        "update": {"sessionUpdate": "tool_call", "title": "Inspecting fixture", "status": "in_progress"},
                    },
                })
                send({
                    "jsonrpc": "2.0",
                    "id": 900,
                    "method": "session/request_permission",
                    "params": {
                        "sessionId": session,
                        "toolCall": {"title": "Edit fixture"},
                        "options": [
                            {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                            {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"},
                        ],
                    },
                })
            elif method == "session/cancel":
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
            elif mid is not None:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method}})
        """
}
