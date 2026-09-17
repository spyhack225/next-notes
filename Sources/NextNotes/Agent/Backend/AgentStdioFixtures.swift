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

    static func writeCDP() throws -> URL {
        try write(name: "nextnotes-cdp-fixture.py", contents: cdp)
    }

    private static func write(name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static let mcp = """
        #!/usr/bin/env python3
        import json, sys, time

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
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "text": {"type": "string", "description": "Text to echo"}
                                },
                                "required": ["text"],
                            },
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
                for chunk in ["ACP", " ", "session", " finished."]:
                    send({
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": session,
                            "update": {
                                "sessionUpdate": "agent_message_chunk",
                                "content": {"type": "text", "text": chunk},
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

    /// Local Chromium `/json/version` + `/json/list` so `--selftest-browser` can prove
    /// CDP discovery without launching Chrome with a debug port.
    static let cdp = """
        #!/usr/bin/env python3
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        import base64, hashlib, struct, time
        import json, sys

        port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
        mode = sys.argv[2] if len(sys.argv) > 2 else "single"

        targets = [{
            "id": "1",
            "type": "page",
            "title": "Example",
            "url": "https://example.com/",
            "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/1" % port,
        }]
        if mode in ("ambiguous", "ambiguous-none"):
            targets = [
                {
                    "id": "1",
                    "type": "page",
                    "title": "Example",
                    "url": "https://example.com/",
                    "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/1" % port,
                },
                {
                    "id": "2",
                    "type": "page",
                    "title": "Docs",
                    "url": "https://developer.example/",
                    "active": mode == "ambiguous",
                    "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/2" % port,
                },
            ]
        elif mode == "stale":
            targets = [{
                "id": "1",
                "type": "page",
                "title": "YouAreStale",
                "url": "https://stale.example/",
                "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/1" % port,
            }]

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def do_GET(self):
                bound = self.server.server_address[1]
                if self.headers.get("Upgrade", "").lower() == "websocket":
                    self.handle_websocket(bound)
                    return
                if self.path.startswith("/json/version"):
                    body = json.dumps({
                        "Browser": "Chrome/fixture",
                        "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools" % bound,
                    })
                elif self.path.startswith("/json"):
                    body = json.dumps([
                        dict(item, webSocketDebuggerUrl=item["webSocketDebuggerUrl"].replace(
                            ":0/", ":%d/" % bound
                        )) for item in targets
                    ])
                else:
                    self.send_error(404)
                    return
                data = body.encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def handle_websocket(self, bound):
                key = self.headers.get("Sec-WebSocket-Key", "")
                accept = base64.b64encode(hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()).decode()
                self.send_response(101, "Switching Protocols")
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()

                active = mode not in ("ambiguous", "ambiguous-none") or (
                    mode == "ambiguous" and self.path.endswith("/2")
                )
                while True:
                    header = self.rfile.read(2)
                    if len(header) != 2:
                        return
                    opcode = header[0] & 0x0f
                    length = header[1] & 0x7f
                    if length == 126:
                        length = struct.unpack("!H", self.rfile.read(2))[0]
                    elif length == 127:
                        length = struct.unpack("!Q", self.rfile.read(8))[0]
                    masked = header[1] & 0x80
                    mask = self.rfile.read(4) if masked else b""
                    payload = self.rfile.read(length)
                    if masked:
                        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                    if opcode == 8:
                        return
                    if opcode not in (1, 2):
                        continue
                    request = json.loads(payload.decode())
                    if mode == "unresponsive":
                        time.sleep(10)
                        return
                    expression = request.get("params", {}).get("expression", "")
                    method = request.get("method", "")
                    if "hasFocus" in expression:
                        value = "focused" if active else "background"
                    elif method == "Runtime.evaluate":
                        value = json.dumps([
                            {"id": "1", "tag": "button", "text": "OK"},
                            {"id": "2", "tag": "input", "text": "Name"},
                        ])
                    elif method == "Page.navigate":
                        value = "navigated"
                    elif method == "Accessibility.getFullAXTree":
                        response = json.dumps({
                            "id": request.get("id"),
                            "result": {"nodes": [
                                {"role": {"value": "button"}, "name": {"value": "OK"}},
                                {"role": {"value": "textbox"}, "name": {"value": "Name"}},
                            ]},
                        }).encode()
                        if len(response) < 126:
                            frame = bytes([0x81, len(response)]) + response
                        elif len(response) <= 65535:
                            frame = b"\\x81\\x7e" + struct.pack("!H", len(response)) + response
                        else:
                            frame = b"\\x81\\x7f" + struct.pack("!Q", len(response)) + response
                        self.wfile.write(frame)
                        self.wfile.flush()
                        continue
                    else:
                        value = "ok"
                    response = json.dumps({
                        "id": request.get("id"),
                        "result": {"result": {"value": value}},
                    }).encode()
                    if len(response) < 126:
                        frame = bytes([0x81, len(response)]) + response
                    elif len(response) <= 65535:
                        frame = b"\\x81\\x7e" + struct.pack("!H", len(response)) + response
                    else:
                        frame = b"\\x81\\x7f" + struct.pack("!Q", len(response)) + response
                    self.wfile.write(frame)
                    self.wfile.flush()

            def log_message(self, *args):
                pass

        httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        print(httpd.server_address[1], flush=True)
        httpd.serve_forever()
        """
}
