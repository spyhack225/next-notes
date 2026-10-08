import Foundation

// Actual source types/helper, ordinary synthetic speech. No ASR, diarizer, live
// native app, model runtime, owner file or speaker-name/provider observation runs.
let quote = "Can you send the reviewed drawing?"
let clock = Date(timeIntervalSince1970: 1_750_000_000.125)
var context = MeetingContext.empty(meetingID: UUID(), title: "Generic identity fixture", participants: ["Confirmed Alex"])
context.questions = [.init(id: "question", text: quote, speaker: "Confirmed Alex", source: .system,
                           confidence: "inferred", createdAt: clock)]
context.candidateActions = [.init(id: "candidate", action: "send", object: "drawing", speaker: "Confirmed Alex",
                                 source: .system, confidence: "inferred", evidence: quote, evidenceStart: 1,
                                 createdAt: clock)]
let live = [TranscriptSegment(start: 1, end: 4, text: quote, source: .system)]
var checks = 0
var failures: [String] = []
func check(_ name: String, _ value: Bool) {
    checks += 1
    if !value { failures.append(name) }
}
for (name, label) in [("nil", Optional<String>.none), ("default", Optional("Others"))] {
    let final = [TranscriptSegment(start: 0.5, end: 4, text: quote, source: .system, speaker: label)]
    let projected = MeetingSpeakerProjection.apply(context, segments: final, liveSegments: live, speakerNames: [:])
    check("\(name) preserves confirmed context item", projected.questions.first?.speaker == "Confirmed Alex")
    check("\(name) preserves confirmed anchored candidate", projected.candidateActions.first?.speaker == "Confirmed Alex")
    var restored = projected
    restored.questions[0].speaker = context.questions[0].speaker
    restored.candidateActions[0].speaker = context.candidateActions[0].speaker
    check("\(name) preserves all other payload fields", restored == context)
}
let identified = [TranscriptSegment(start: 0.5, end: 4, text: quote, source: .system, speaker: "Speaker 1")]
check("identified speaker uses existing confirmed mapping",
      MeetingSpeakerProjection.apply(context, segments: identified, liveSegments: live,
          speakerNames: ["Speaker 1": "Confirmed Alex"]) == context)
for (name, label) in [("nil", Optional<String>.none), ("default", Optional("Others"))] {
    let final = [TranscriptSegment(start: 0.5, end: 4, text: quote, source: .system, speaker: label)]
    let projected = MeetingSpeakerProjection.apply(context, segments: final, liveSegments: live,
        speakerNames: ["Others": "Confirmed Room"])
    check("\(name) honors explicit manual mapping on context item", projected.questions.first?.speaker == "Confirmed Room")
    check("\(name) honors explicit manual mapping on candidate", projected.candidateActions.first?.speaker == "Confirmed Room")
    check("\(name) mapping retains system source", projected.questions.first?.source == .system
        && projected.candidateActions.first?.source == .system)
}
let wrongSource = [TranscriptSegment(start: 0.5, end: 4, text: quote, source: .mic, speaker: "Speaker 1")]
check("other track cannot supply identity",
      MeetingSpeakerProjection.apply(context, segments: wrongSource, liveSegments: live,
          speakerNames: ["Speaker 1": "Other Person"]) == context)
for failure in failures { print("MEETING_SPEAKER_DEFAULT_WRONG: \(failure)") }
print("MEETING_SPEAKER_DEFAULT_\(failures.isEmpty ? "OK" : "FAILED") checks=\(checks) failures=\(failures.count)")
if !failures.isEmpty { exit(1) }
