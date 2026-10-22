import Foundation
import Darwin
struct LLMChatMessage { enum Role: String { case user, assistant, system }; let role: Role; let content: String }
enum SelfTest { static func diagnostic(_ value: String) { print(value) } }
enum NotesModelRuntime {
 static func streamPiecesForTesting(_ pieces: [String], family: ChatTemplateFamily, renderSpecial: Bool = true) -> AsyncThrowingStream<String, Error> {
  AsyncThrowingStream { continuation in
   var output = ChatTemplateStreamOutput(family: family, renderSpecial: renderSpecial)
   for piece in pieces { output.consume(piece, yield: { continuation.yield($0) }); if output.stopped { break } }
   output.finish(yield: { continuation.yield($0) }); continuation.finish()
  }
 }
}
@main enum StreamTests {
 static func quoted(_ text: String) -> String { text }
 static func main() async { let failures = await streamOutputFailures(); for failure in failures { print(failure) }; exit(failures.isEmpty ? 0 : 1) }
    static func streamOutputFailures() async -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ family: ChatTemplateFamily, _ pieces: [String],
                   _ expected: String, forbidden: [String] = [], renderSpecial: Bool = true) async {
            checks += 1
            var callbacks: [String] = []
            do {
                for try await piece in NotesModelRuntime.streamPiecesForTesting(pieces, family: family, renderSpecial: renderSpecial) {
                    callbacks.append(piece)
                }
            } catch {
                failures.append("stream \(name): unexpected error \(error)")
            }
            let actual = callbacks.joined()
            if actual.utf8.elementsEqual(expected.utf8) == false {
                failures.append("stream \(name): \(quoted(actual)), expected \(quoted(expected))")
            }
            if callbacks.contains(where: { piece in forbidden.contains(where: { piece.contains($0) }) }) {
                failures.append("stream \(name): forbidden text reached a callback")
            }
        }
        let families: [ChatTemplateFamily] = [
            .chatmlThinking, .chatml, .minicpm5, .llama3, .gemma, .gemma4, .unsupported,
        ]
        let plain = "  Café e\u{301} 👩🏽‍💻\n2 < 3; <literal> & \"quoted\".\n"
        let miniTool = "<function name=\"x\"><param name=\"k\">v</param></function>"
        let qwenTool = "<tool_call>{\"name\":\"x\",\"arguments\":{}}</tool_call>"
        for family in families {
            await check("plain-\(family.rawValue)", family, plain.map(String.init), plain)
            await check("tools-\(family.rawValue)", family, (miniTool + qwenTool).map(String.init), miniTool + qwenTool)
            for marker in ChatTemplate.controlMarkers(family) {
                for split in 1..<marker.count {
                    let pieces = ["Before", String(marker.prefix(split)), String(marker.dropFirst(split)), "After"]
                    let expected = marker == ChatTemplate.stopMarker(family) || marker == "<think>" || marker == "<|channel>"
                        ? "Before" : "BeforeAfter"
                    await check("marker-\(family.rawValue)-\(marker)-\(split)", family, pieces, expected,
                                forbidden: [marker])
                }
            }
            if !ChatTemplate.stopMarker(family).isEmpty {
                await check("stop-and-tail-\(family.rawValue)", family,
                            ["Answer" + ChatTemplate.stopMarker(family) + "ignored", "ignored"], "Answer")
            }
        }
        for family in [ChatTemplateFamily.chatmlThinking, .chatml, .minicpm5, .gemma4] {
            let source = "<think>PRIVATE</think>Answer"
            for split in 0...source.count {
                await check("thinking-\(family.rawValue)-\(split)", family,
                            [String(source.prefix(split)), String(source.dropFirst(split))], "Answer",
                            forbidden: ["PRIVATE", "<think>", "</think>"])
            }
            await check("one-character-\(family.rawValue)", family, source.map(String.init), "Answer")
            await check("unfinished-\(family.rawValue)", family, ["Before<think>", "PRIVATE", "</thi"], "Before")
            await check("multiple-\(family.rawValue)", family,
                        ["A<think>PRIVATE</think>B<think>PRIVATE</think>C"], "ABC")
            await check("stray-close-\(family.rawValue)", family, ["</thi", "nk>Answer"], "Answer")
            await check("thinking-tools-\(family.rawValue)", family,
                        ["<think>PRIVATE</think>" + miniTool + qwenTool], miniTool + qwenTool)
        }
        // Gemma's thought channel closes with <channel|>; <|think|> itself is a
        // system switch, not the beginning of an output block.
        let gemmaThought = "<|channel>thought\nPRIVATE\n<channel|>Answer"
        for split in 0...gemmaThought.count {
            await check("gemma-thought-\(split)", .gemma4,
                        [String(gemmaThought.prefix(split)), String(gemmaThought.dropFirst(split))],
                        "Answer", forbidden: ["PRIVATE", "thought", "<|channel>", "<channel|>"])
        }
        await check("gemma-character-thought", .gemma4, gemmaThought.map(String.init), "Answer")
        await check("gemma-switch", .gemma4, ["<|think|>Answer"], "Answer")
        await check("gemma-unfinished", .gemma4, ["Before<|channel>thought\nPRIVATE"], "Before")
        await check("nested", .minicpm5,
                    ["<think>PRIVATE<think>PRIVATE</think>PRIVATE</think>Answer"], "Answer")
        await check("interleaved-gemma", .gemma4,
                    ["<think>PRIVATE<|channel>thought\nPRIVATE</think>PRIVATE<channel|>Answer"], "Answer")
        // V1 expected "Answer" here and incorrectly rewarded visible byte loss.
        await check("truncated-opening", .minicpm5, ["Answer<thi"], "Answer<thi")
        await check("lone-angle-eof", .minicpm5, ["<"], "<")
        await check("comparison-eof", .minicpm5, ["2 ", "<"], "2 <")
        // Every proper control prefix is ordinary text once EOF rules out completion.
        for family in families {
            for prefix in Set(ChatTemplate.controlMarkers(family).flatMap { marker in
                (1..<marker.count).map { String(marker.prefix($0)) }
            }).sorted() {
                await check("visible-prefix-eof-\(family.rawValue)-\(prefix)", family,
                            ["Answer", prefix], "Answer" + prefix)
            }
            if !ChatTemplate.stopMarker(family).isEmpty {
                await check("non-special-prefix-eof-\(family.rawValue)", family,
                            ["Answer", String(ChatTemplate.stopMarker(family).dropLast())],
                            "Answer" + String(ChatTemplate.stopMarker(family).dropLast()),
                            renderSpecial: false)
                await check("non-special-stop-\(family.rawValue)", family,
                            ["A", ChatTemplate.stopMarker(family), "ignored<"], "A",
                            renderSpecial: false)
            }
        }
        await check("non-special-literal-thinking", .minicpm5,
                    ["A<think>PRIVATE</think>B<"], "A<think>PRIVATE</think>B<",
                    renderSpecial: false)
        await check("unclosed-hidden-prefix", .minicpm5,
                    ["A<think>", "PRIVATE<"], "A", forbidden: ["PRIVATE", "<"])
        await check("unclosed-channel-prefix", .gemma4,
                    ["A<|channel>", "thought PRIVATE<chan"], "A", forbidden: ["PRIVATE", "<"])

        // Synchronous callback position, using the very producer called by the
        // scheduled native loop. Joined streams alone cannot detect delayed release.
        func checkProgress(_ name: String, _ pieces: [String], _ progress: [String],
                           _ finished: String, eofCallbacks: [String]) {
            checks += 1
            var output = ChatTemplateStreamOutput(family: .minicpm5, renderSpecial: true)
            var callbacks: [String] = []
            for (index, piece) in pieces.enumerated() {
                output.consume(piece, yield: { callbacks.append($0) })
                let actual = callbacks.joined()
                if actual != progress[index] {
                    failures.append("stream \(name) piece \(index): \(quoted(actual)), expected \(quoted(progress[index]))")
                }
            }
            let beforeEOF = callbacks.count
            output.finish(yield: { callbacks.append($0) })
            if callbacks.joined() != finished || Array(callbacks.dropFirst(beforeEOF)) != eofCallbacks {
                failures.append("stream \(name) EOF: \(quoted(callbacks.joined())), callbacks \(Array(callbacks.dropFirst(beforeEOF))); expected \(quoted(finished)), callbacks \(eofCallbacks)")
            }
            let afterEOF = callbacks
            output.finish(yield: { callbacks.append($0) })
            if callbacks != afterEOF { failures.append("stream \(name): finish emitted twice") }
        }
        checkProgress("release-disproved-prefix", ["A<", "x", "B"],
                      ["A", "A<x", "A<xB"], "A<xB", eofCallbacks: [])
        checkProgress("release-visible-prefix-at-eof", ["A<"], ["A"], "A<", eofCallbacks: ["<"])
        checkProgress("release-lone-angle-at-eof", ["<"], [""], "<", eofCallbacks: ["<"])
        checkProgress("hide-unclosed-tail-at-eof", ["A<think>", "PRIVATE</thi"],
                      ["A", "A"], "A", eofCallbacks: [])
        checkProgress("stop-discards-tail-at-eof", ["A<|im_end|>ignored<", "B"],
                      ["A", "A"], "A", eofCallbacks: [])
        SelfTest.diagnostic("CHAT_TEMPLATE_STREAM: \(checks) cases, \(failures.count) failures; decoded pieces -> producer callbacks -> completed stream")
        return failures
    }


}
