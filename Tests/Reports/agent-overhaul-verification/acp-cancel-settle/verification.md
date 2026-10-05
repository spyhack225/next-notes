# ACP cancellation settles its own request

Cancelling an ACP prompt now removes and settles its exact pending JSON-RPC request. The transport stays available to an unrelated request; response, close and cancellation settle each continuation once.

Focused verification: actual consumed-request fixture in original app408 failed four of 32 checks; the unchanged fixture in app409 passed all 32. MCP, confirmation and owner-store isolation also passed. Historical aggregate and timing failures are retained separately; this is not process-death, remote-effect or recovery proof.

Raw comparison archive: `~/Library/Caches/NextNotesBuild/evidence/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/{stdio-cancel-original408,stdio-cancel-fixed409}`. Later final-response timing failures do not establish double settlement and remain open.
