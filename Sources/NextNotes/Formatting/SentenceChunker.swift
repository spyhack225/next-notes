import Foundation

/// Splits a long transcript into sentence groups, so a minute of speech is several small
/// model calls instead of one that misses its deadline.
///
/// ## The failure this removes
///
/// Both cleanup engines have a ceiling and both used to hand the whole utterance to it at
/// once. `S1MiniFormatter` capped every transcript at eight seconds regardless of length, and
/// `S1MiniRuntime` refuses an input over 1,600 tokens outright; `FoundationModelFormatter`
/// grows its deadline with the input but stops at twelve seconds and 1,200 response tokens.
/// Measured on this Mac from `metrics.jsonl`: a 19.6 s dictation cleaned in 3.2 s and a 98.3 s
/// one took 7.1 s — so a two-minute hold was already inside a second of the S1 ceiling, and
/// past it the whole pass fails and the *raw* transcript is typed. That is exactly the
/// "long dictations come out with ASR errors in them" report: not a worse cleanup, no cleanup.
///
/// Giving up is also the wrong shape of failure. A transcript is a sequence of sentences and
/// cleanup is local to each of them, so losing one group to a timeout should cost that
/// paragraph and not the utterance.
///
/// ## Why sentence groups and not a fixed token count
///
/// Cutting mid-sentence would hand the model half a clause and ask it to repair the grammar
/// of something that is not a sentence — which is how a chunked pass invents an ending. The
/// split is therefore always on a sentence terminator, and a single sentence longer than the
/// budget is passed whole rather than cut.
enum SentenceChunker {

    /// Groups of whole sentences, each at most `maxWords` words unless one sentence is
    /// longer than that on its own.
    static func chunks(_ text: String, maxWords: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard wordCount(trimmed) > maxWords else { return [trimmed] }

        var groups: [String] = []
        var current = ""
        var currentWords = 0

        for sentence in sentences(in: trimmed) {
            let words = wordCount(sentence)
            if currentWords > 0, currentWords + words > maxWords {
                groups.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                currentWords = 0
            }
            // A paragraph break inside the transcript is kept, so the model is not handed a
            // run-on where the speaker changed topic.
            if !current.isEmpty { current += sentence.hasPrefix("\n") ? "" : " " }
            current += sentence
            currentWords += words
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { groups.append(tail) }
        return groups
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Sentence split that keeps the terminator, and keeps a blank line as its own boundary.
    ///
    /// Shared with `CleanupGuard.salvage`, which judges a rejected answer sentence by
    /// sentence: the two must agree on where a sentence ends or the pairs it lines up are
    /// not pairs.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let iterator = Array(text)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            current.append(character)
            if ".!?".contains(character) {
                // Not a boundary inside "3.5" or "e.g." — a terminator is only one when what
                // follows is whitespace or the end.
                let next = index + 1 < iterator.count ? iterator[index + 1] : " "
                if next.isWhitespace || next.isNewline {
                    result.append(current)
                    current = ""
                }
            } else if character == "\n", current.hasSuffix("\n\n") {
                result.append(current)
                current = ""
            }
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Runs an inner formatter over sentence groups and reassembles the result.
///
/// Each group is an independent call, so one that fails degrades to its own input rather
/// than to the whole raw transcript. That is the entire point: with the old single call, one
/// slow group meant the user got their unpunctuated ASR back.
///
/// Transparent below the threshold — a normal utterance is one group and one call, and this
/// type costs a word count.
struct ChunkedFormatter: TextFormatter {
    let inner: any TextFormatter
    /// Sized against the two engines' real limits rather than a round number. S1-mini refuses
    /// over ~1,600 tokens and both engines cap generation at 1,200; 120 words is roughly 160
    /// tokens in and out, which keeps every call in the range both models were measured fast
    /// at (0.5–0.7 s warm) with a wide margin on the context window.
    var maxWords: Int = 120
    /// Written with the number of groups, so the per-run record says whether a dictation was
    /// chunked at all.
    var trace: CleanupTrace?
    /// The whole pass's budget, not one call's.
    ///
    /// Chunking trades one long call for several short ones, and several short ones can add
    /// up past the bound `DictationController.Limits.cleanup` puts on the *whole* stage —
    /// which would hand the user the raw transcript and lose every group that had already
    /// been cleaned. So the tail of a very long dictation is left as spoken instead, which is
    /// the same trade the outer bound makes and a far smaller one.
    ///
    /// Four seconds under the controller's thirty, and `perCallTimeout` is what makes that
    /// margin real: the budget is checked against the *next call's own ceiling*, so a group
    /// can never be started that is allowed to run past the end of it. Checking only that
    /// the clock had time left was the bug — a group dispatched at 21.9 s could still sit in
    /// S1-mini for its own fifteen, overshoot the outer deadline, and lose every group
    /// already cleaned.
    var budget: Duration = .seconds(26)

    /// The ceiling one call on this text is allowed to run for — the inner formatter's own
    /// timeout, so the two numbers cannot drift apart.
    ///
    /// The default is S1-mini's, the larger of the two shipping engines (15 s against
    /// Apple's 12 s), so an unwired caller errs towards stopping early rather than towards
    /// overshooting.
    var perCallTimeout: @Sendable (String) -> Duration = { S1MiniFormatter.timeout(for: $0) }

    /// How many groups may be in the model at once.
    ///
    /// Two, and the number is a measurement rather than a preference. A forty-one second
    /// dictation is two groups, and run one after the other on this Mac they cost 9.3 s of
    /// the user's time — the single largest term in the wait, and the reason a dictation
    /// that is otherwise correct still feels unpolished. The groups are independent by
    /// construction: cleanup is local to a sentence, which is the whole premise of chunking.
    ///
    /// Not unbounded, because a three-minute dictation is eight groups and eight concurrent
    /// requests to one on-device model is not eight times faster — it is memory pressure and
    /// a scheduler fighting the live transcription path. Two is the width that halves the
    /// common case without asking the machine for anything it does not have.
    var width: Int = 2

    func format(_ raw: String) async -> String {
        let groups = SentenceChunker.chunks(raw, maxWords: maxWords)
        trace?.noteChunks(max(1, groups.count))
        guard groups.count > 1 else {
            return await inner.format(raw)
        }
        Log.speech.info("cleanup · \(groups.count, privacy: .public) sentence group(s)")
        let began = ContinuousClock.now
        var pieces = [String?](repeating: nil, count: groups.count)
        var ranOut = false
        var next = 0

        // Waves of `width`, rather than a task group fed one at a time: the budget check has
        // to happen between waves, and a group that is already in flight cannot be
        // un-started. Order is restored by index, so the transcript comes back in the order
        // it was spoken whichever call finishes first.
        while next < groups.count {
            let wave = Array(next..<min(next + max(1, width), groups.count))
            // Room for this wave to finish inside the budget, not merely room to start it.
            // The ceiling is the longest call in the wave, because they run together.
            let remaining = budget - (ContinuousClock.now - began)
            let ceiling = wave.map { perCallTimeout(groups[$0]) }.max() ?? .zero
            if ranOut || remaining <= .zero || remaining < ceiling {
                if !ranOut {
                    ranOut = true
                    trace?.noteTruncated(
                        reason: "that dictation was long, so the end of it was left as spoken"
                    )
                    Log.speech.error("cleanup · out of budget; remaining groups left as spoken")
                }
                for index in wave { pieces[index] = groups[index] }
                next += wave.count
                continue
            }
            let inner = inner
            let cleanedWave = await withTaskGroup(of: (Int, String).self) { group in
                for index in wave {
                    let text = groups[index]
                    group.addTask {
                        let result = await inner.format(text)
                        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                        return (index, trimmed.isEmpty ? text : trimmed)
                    }
                }
                var done: [(Int, String)] = []
                for await result in group { done.append(result) }
                return done
            }
            for (index, piece) in cleanedWave { pieces[index] = piece }
            next += wave.count
        }

        var cleaned = ""
        for (index, piece) in pieces.enumerated() {
            let piece = piece ?? groups[index]
            if cleaned.isEmpty {
                cleaned = piece
            } else if cleaned.hasSuffix("\n") {
                // A paragraph break the speaker asked for survives the seam.
                cleaned += piece
            } else {
                cleaned += " " + piece
            }
        }
        return cleaned
    }
}
