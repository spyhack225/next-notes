
// Mechanical adapter of baseline streamWhileScheduled decoded-piece block.
// Only native decoding/sampling, tracing/counting and loop exit are substituted.
struct ChatTemplateStreamOutput {
 let family: ChatTemplateFamily
 let renderSpecial: Bool
 let turnEnd: String
 var pending = ""
 var stopped = false
 init(family: ChatTemplateFamily, renderSpecial: Bool) { self.family = family; self.renderSpecial = renderSpecial; turnEnd = ChatTemplate.stopMarker(family) }
 mutating func consume(_ incoming: String, yield: (String)->Void) {
 guard !stopped else { return }
                var piece = incoming
                if renderSpecial {
                    // A plain answer must not speak a family's turn or thinking markers. The
                    // stop marker is excluded: the holdback below needs it to end the turn.
                    for marker in ChatTemplate.controlMarkers(family) where marker != turnEnd {
                        piece = piece.replacingOccurrences(of: marker, with: "")
                    }
                }
                pending += piece
                // Hold a suffix that could still become the family's terminator. This avoids
                // sending its fragments into the spoken-reply bridge.
                let maxHeld = min(turnEnd.count, pending.count)
                let held: Int
                if maxHeld == 0 {
                    held = 0
                } else {
                    held = (1...maxHeld).reversed().first {
                        String(pending.suffix($0)) == String(turnEnd.prefix($0))
                    } ?? 0
                }
                let safeCount = pending.count - held
                if safeCount > 0 {
                    yield(String(pending.prefix(safeCount)))
                    pending.removeFirst(safeCount)
                }
                if !turnEnd.isEmpty, pending == turnEnd {
                    pending = ""
                    stopped = true
                    return
                }


 }
 mutating func finish(yield: (String)->Void) { if !pending.isEmpty, turnEnd.isEmpty || !pending.hasPrefix(turnEnd) { yield(pending) } }
}
