from pathlib import Path
p = Path('Sources/NextNotes/UI/CatchUp/CatchUpLibrary.swift')
s = p.read_text()
s = s.replace('''    func say(_ text: String, for entry: CatchUpEntry) {
        say(text)
    }''', '''    func say(_ text: String, for entry: CatchUpEntry) {
        (session ?? .shared).recordBackgroundTask(entry.text, taskID: entry.id)
        say(text)
    }''', 1)
s = s.replace('''    @MainActor static var live: Self {''', '''    var permitsPlayback: Bool {
        activationIdle && !dictating && !recording && !speaking && !callActive
    }

    @MainActor static var live: Self {''', 1)
s = s.replace('''        guard let url = entry.audioURL else { return }
        do {''', '''        guard let url = entry.audioURL, permitPlayback() else { return }
        do {''', 1)
s = s.replace('''    private func resume(_ player: any CatchUpAudioPlaying) {
        guard player.play() else { return }''', '''    private func resume(_ player: any CatchUpAudioPlaying) {
        guard permitPlayback(), player.play() else { return }''', 1)
s = s.replace('''        guard let player else { return }
        elapsed = player.currentTime
        if !activity().activationIdle {''', '''        guard isPlaying, let player else { return }
        elapsed = player.currentTime
        if !permitPlayback() {''', 1)
s = s.replace('''    func pollPlayback() {''', '''    /// No await: read the same activity facts before opening/starting/resuming a file
    /// and on the existing tick. Never resumes automatically when the activity ends.
    private func permitPlayback() -> Bool {
        guard activity().permitsPlayback else {
            problem = "Finish talking or recording, then try Play again."
            return false
        }
        problem = nil
        return true
    }

    func pollPlayback() {''', 1)
p.write_text(s)
p = Path('Sources/NextNotes/Agent/RealtimeAgent.swift')
s = p.read_text()
s = s.replace('''        var contextKind: String? = nil
''', '''        var contextKind: String? = nil
        /// Identity of a background result already brought into this conversation.
        /// Optional keeps old saved rows readable; this conveys no action authority.
        var contextTaskID: String? = nil
''', 1)
s = s.replace('''    func recordAssistant(_ text: String, contextKind: String? = nil,
''', '''    func recordAssistant(_ text: String, contextKind: String? = nil, contextTaskID: String? = nil,
''', 1)
s = s.replace('''            contextKind: contextKind, toolResultIDs: verifiedIDs.isEmpty ? nil : Array(verifiedIDs),''', '''            contextKind: contextKind, contextTaskID: contextTaskID,
            toolResultIDs: verifiedIDs.isEmpty ? nil : Array(verifiedIDs),''', 1)
p.write_text(s)
Path('Sources/NextNotes/UI/CatchUp/CatchUpConversationContext.swift').write_text('''import Foundation

@MainActor
extension AgentSession {
    /// A retained background result grounds an ordinary follow-up in this session.
    /// End an idle session BEFORE the result, so recordUser does not orphan it.
    /// Deduplicate by producer identity on the existing rows, never by matching words.
    func recordBackgroundTask(_ text: String, taskID: String) {
        endSessionIfIdle()
        guard !currentSessionMessages.contains(where: {
            $0.contextKind == Self.backgroundTaskContextKind && $0.contextTaskID == taskID
        }) else { return }
        recordAssistant(text, contextKind: Self.backgroundTaskContextKind, contextTaskID: taskID)
    }
}
''')
