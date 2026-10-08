# Next related cancellation contract (unreproduced, not patched)

The existing per-hold PrecleanLane stores waiting continuations without cancellation handlers. Session.cancel cancels every group Task, but an already-waiting Task can only observe cancellation after the current semantic producer releases this lane. The closure then avoids a new model call and returns its original text. Therefore this is not evidence of extra model work or of a global queue delaying the next hold: each hold owns its lane. Potential retained-task/memory delay requires a reproduction.

A focused same-file actual session fixture should hold the first semantic call, close a second stable committed group, wait until the existing lane has registered it, cancel the session, and require that second group joins as its original StageA text before releasing the first semantic call. Verify zero second model entries, unchanged first owner, exact grouping/order and a non-cancelled wait. Release/join all actual groups on every exit. If confirmed, repair existing waiting entries with identity/cancellation settlement rather than adding another queue. A cancellation result must fall back to that group, never empty text. Do not delete single-call serial admission or silently turn two groups into simultaneous Apple calls.

Original producer pin:

```swift
private actor PrecleanLane {
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(_ body: @Sendable () async -> String) async -> String {
        if held {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            held = true
        }
        let answer = await body()
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
        return answer
    }
}

```
