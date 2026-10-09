from pathlib import Path
root=Path(__file__).resolve().parents[4]
p=root/'Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift'
s=p.read_text()
old='''        guard token == currentPlaybackToken, !didStop,
              replyVoiceRequest == selectedVoiceRequest,
              let currentClause, !currentClause.isEmpty,'''
new='''        guard token == currentPlaybackToken, !didStop,
              let currentClause, !currentClause.isEmpty,'''
assert s.count(old)==1
s=s.replace(old,new).replace('''        selectedVoiceFailed = true
        outputAvailability = .failed''','''        // The token/text owns output settlement. Epochs fence only the
        // selected voice latch: selection/preparation does not replace playback.
        if let request = replyVoiceRequest { noteSelectedVoiceFailure(request: request) }
        outputAvailability = .failed''')
s=s.replace('guard !trimmed.isEmpty, !didStop else { return }','''guard !trimmed.isEmpty,
              !didStop || (!replyCanSpeak && outputAvailability == .failed) else { return }''')
s=s.replace('if advanceGeneration { outputGeneration &+= 1 }','''if advanceGeneration {
            outputGeneration &+= 1
            // An explicit stop ends text admission too. Failed output retains
            // this generation so its remaining stream can settle unheard.
            replyCanSpeak = true
        }''')
p.write_text(s)
