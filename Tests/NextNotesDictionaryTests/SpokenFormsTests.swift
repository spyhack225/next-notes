import Foundation
import Testing

@testable import NextNotesDictionary

/// Runs the shared spoken-form contract in `shared/spoken-forms-test-vectors.json`.
///
/// The same arrangement as `VectorTests`, and for the same reason: the numbers in that file
/// are the specification, and a change to how names are matched starts there rather than
/// here. The one honest difference is that there is nothing on the other side of the
/// contract yet — no C# `SpokenForms` runs these cases — so today this suite is the only
/// thing standing between the scoring arithmetic and a silent rewrite. It is also the only
/// coverage the file tagging feature has at all: CI cannot build the app target, so
/// everything in `Context/` and every formatter change is checked by hand, and this is not.
///
/// Named `SpokenFormsTests` and not `SpokenFormsVectorTests` on purpose. The Makefile and
/// the workflow both filter by suite name, and a name ending in "VectorTests" would be swept
/// up by the existing `--filter VectorTests` by accident — passing until the day somebody
/// renames something, which is worse than never having run.
struct SpokenFormsTests {

    // MARK: - The file

    struct Vectors: Decodable {
        let version: Int
        let tokenize: [TokenizeCase]
        let identifiers: [IdentifierCase]
        let phoneticKeys: [PhoneticKeyCase]
        let phoneticMatches: [PhoneticMatchCase]
        let variants: [VariantCase]
        let scores: [ScoreCase]
        let bestMatches: [BestMatchCase]
        let bias: [BiasCase]
    }

    struct TokenizeCase: Decodable {
        let note: String
        let input: String
        let expect: [ExpectedToken]

        struct ExpectedToken: Decodable {
            let text: String
            let start: Int
            let length: Int
        }
    }

    struct IdentifierCase: Decodable {
        let note: String
        let name: String
        let basename: String
        let pathSegments: [String]
        let `extension`: String?
        let tokens: [String]
    }

    struct PhoneticKeyCase: Decodable {
        let token: String
        let primary: String
        let alternate: String?
    }

    struct PhoneticMatchCase: Decodable {
        let a: String
        let b: String
        let matches: Bool
    }

    struct VariantCase: Decodable {
        let note: String
        let name: String
        let biasPhrase: String?
        let expect: [String]
    }

    struct ScoreCase: Decodable {
        let note: String
        let spoken: String
        let name: String
        let score: Double
        let confident: Bool
        let plausible: Bool
        let matchedTokenCount: Int
        let nameTokenCount: Int
        // Absent means false. Written that way so the common case is not 25 lines of
        // "namedExtension": false, and read with `decodeIfPresent` rather than a synthesized
        // initializer, which throws `keyNotFound` on an absent key however it is defaulted.
        let namedExtension: Bool?
        let namedOtherExtension: Bool?
    }

    struct BestMatchCase: Decodable {
        let note: String
        let transcript: String
        let name: String
        let score: Double
        let confident: Bool
        let spokenTokens: [Int]
    }

    struct BiasCase: Decodable {
        let note: String
        let dictionary: [String]
        let harvested: [String]
        let limit: Int?
        let harvestedShare: Int?
        let expect: [String]
    }

    static func load() throws -> Vectors {
        let url = try #require(
            Bundle.module.url(forResource: "spoken-forms-test-vectors", withExtension: "json")
        )
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    /// Score equality to within 0.0005, which is the tolerance the vectors document.
    ///
    /// Tight enough that a changed weight or a dropped bonus fails, loose enough that the
    /// six decimal places written in the file do not have to be reproduced bit for bit by an
    /// implementation that sums the same terms in a different order.
    static func isClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.0005 }

    // MARK: - Vectors

    @Test("the vectors file is the version this suite understands")
    func version() throws {
        let vectors = try Self.load()
        #expect(vectors.version == 1)
    }

    @Test("tokenizing produces the contracted words and UTF-16 offsets")
    func tokenize() throws {
        let vectors = try Self.load()
        #expect(vectors.tokenize.isEmpty == false)

        for testCase in vectors.tokenize {
            let tokens = SpokenForms.tokenize(spoken: testCase.input)
            #expect(
                tokens.count == testCase.expect.count,
                "\(testCase.note): token count — got \(tokens.map(\.text))"
            )
            for (token, expected) in zip(tokens, testCase.expect) {
                #expect(token.text == expected.text, "\(testCase.note): text")
                #expect(token.start == expected.start, "\(testCase.note): start of “\(expected.text)”")
                #expect(token.length == expected.length, "\(testCase.note): length of “\(expected.text)”")

                // The offsets have to address the original string, not the lowercased one.
                // Reading the span back is the only assertion that catches a port that
                // tokenized a normalized copy and reported offsets into that.
                let utf16 = Array(testCase.input.utf16)
                let span = String(
                    decoding: utf16[token.start..<(token.start + token.length)],
                    as: UTF16.self
                )
                #expect(
                    span.lowercased() == token.text,
                    "\(testCase.note): the span at \(token.start)+\(token.length) reads “\(span)”"
                )
            }
        }
    }

    @Test("names split into the contracted basename, segments, extension and tokens")
    func identifiers() throws {
        let vectors = try Self.load()
        #expect(vectors.identifiers.isEmpty == false)

        for testCase in vectors.identifiers {
            #expect(SpokenForms.basename(of: testCase.name) == testCase.basename, "\(testCase.note): basename")
            #expect(SpokenForms.pathSegments(of: testCase.name) == testCase.pathSegments, "\(testCase.note): segments")
            #expect(SpokenForms.fileExtension(of: testCase.name) == testCase.extension, "\(testCase.note): extension")
            #expect(
                SpokenForms.tokens(of: testCase.basename) == testCase.tokens,
                "\(testCase.note): tokens — got \(SpokenForms.tokens(of: testCase.basename))"
            )
        }
    }

    @Test("every phonetic key is exactly the pair the vectors spell out")
    func phoneticKeys() throws {
        let vectors = try Self.load()
        #expect(vectors.phoneticKeys.isEmpty == false)

        for testCase in vectors.phoneticKeys {
            let key = SpokenForms.phoneticKey(for: testCase.token)
            #expect(key.primary == testCase.primary, "\(testCase.token): primary — got \(key.primary)")
            #expect(
                key.alternate == testCase.alternate,
                "\(testCase.token): alternate — got \(key.alternate ?? "nil")"
            )
            #expect(key.primary.count <= 4, "\(testCase.token): primary is truncated to four")
            #expect((key.alternate?.count ?? 0) <= 4, "\(testCase.token): alternate is truncated to four")
        }
    }

    @Test("the pairs that must meet phonetically do, and the pairs that must not do not")
    func phoneticMatches() throws {
        let vectors = try Self.load()
        #expect(vectors.phoneticMatches.isEmpty == false)

        for testCase in vectors.phoneticMatches {
            let a = SpokenForms.phoneticKey(for: testCase.a)
            let b = SpokenForms.phoneticKey(for: testCase.b)
            #expect(a.matches(b) == testCase.matches, "\(testCase.a) vs \(testCase.b)")
            // Symmetry is not decoration: the caller has no idea which side is the heard
            // word, and an asymmetric match would make the score depend on argument order.
            #expect(b.matches(a) == testCase.matches, "\(testCase.b) vs \(testCase.a), reversed")
        }
    }

    @Test("variants and bias phrases come out in the contracted order")
    func variants() throws {
        let vectors = try Self.load()
        #expect(vectors.variants.isEmpty == false)

        for testCase in vectors.variants {
            let variants = SpokenForms.variants(of: testCase.name)
            #expect(variants == testCase.expect, "\(testCase.note) — got \(variants)")
            #expect(
                SpokenForms.biasPhrase(for: testCase.name) == testCase.biasPhrase,
                "\(testCase.note): bias phrase"
            )
            #expect(variants.count <= SpokenForms.variantLimit, "\(testCase.note): within the cap")
            #expect(
                Set(variants.map { $0.lowercased() }).count == variants.count,
                "\(testCase.note): deduplicated case-insensitively"
            )
        }
    }

    @Test("every score is the contracted number and the contracted verdict")
    func scores() throws {
        let vectors = try Self.load()
        #expect(vectors.scores.isEmpty == false)

        for testCase in vectors.scores {
            let match = SpokenForms.score(spoken: testCase.spoken, against: testCase.name)

            // Both halves, always. The number alone turns a threshold change into fifty
            // vector edits; the verdict alone lets an implementation sit at 0.719 forever
            // and still report green.
            #expect(
                Self.isClose(match.score, testCase.score),
                "\(testCase.note): score — got \(match.score), expected \(testCase.score)"
            )
            #expect(match.isConfident == testCase.confident, "\(testCase.note): confident")
            #expect(match.isPlausible == testCase.plausible, "\(testCase.note): plausible")
            #expect(match.matchedTokenCount == testCase.matchedTokenCount, "\(testCase.note): matched count")
            #expect(match.nameTokenCount == testCase.nameTokenCount, "\(testCase.note): name token count")
            #expect(
                match.namedExtension == (testCase.namedExtension ?? false),
                "\(testCase.note): namedExtension"
            )
            #expect(
                match.namedOtherExtension == (testCase.namedOtherExtension ?? false),
                "\(testCase.note): namedOtherExtension"
            )

            // The range has to address the tokens of the phrase that was passed in, or a
            // caller highlighting the reference highlights the wrong words.
            let tokenCount = SpokenForms.tokenize(spoken: testCase.spoken).count
            #expect(match.spokenTokens.lowerBound >= 0, "\(testCase.note): range starts inside the phrase")
            #expect(match.spokenTokens.upperBound <= max(tokenCount, 0), "\(testCase.note): range ends inside the phrase")
        }
    }

    @Test("the best window of a sentence is the contracted one")
    func bestMatches() throws {
        let vectors = try Self.load()
        #expect(vectors.bestMatches.isEmpty == false)

        for testCase in vectors.bestMatches {
            let match = SpokenForms.bestMatch(of: testCase.name, in: testCase.transcript)
            #expect(
                Self.isClose(match.score, testCase.score),
                "\(testCase.note): score — got \(match.score)"
            )
            #expect(match.isConfident == testCase.confident, "\(testCase.note): confident")
            #expect(
                [match.spokenTokens.lowerBound, match.spokenTokens.upperBound] == testCase.spokenTokens,
                "\(testCase.note): window — got \(match.spokenTokens)"
            )

            let tokens = SpokenForms.tokenize(spoken: testCase.transcript)
            #expect(match.spokenTokens.upperBound <= tokens.count, "\(testCase.note): window is inside the transcript")
        }
    }

    @Test("the bias budget is merged exactly as the contract says")
    func bias() throws {
        let vectors = try Self.load()
        #expect(vectors.bias.isEmpty == false)

        for testCase in vectors.bias {
            let merged = SpokenForms.mergedBiasPhrases(
                dictionary: testCase.dictionary,
                harvested: testCase.harvested,
                limit: testCase.limit ?? DictionaryCorrector.biasLimit,
                harvestedShare: testCase.harvestedShare ?? SpokenForms.harvestedBiasShare
            )
            #expect(merged == testCase.expect, "\(testCase.note) — got \(merged)")
        }
    }

    // MARK: - Properties the vectors cannot state

    @Test("the two thresholds stay in the order the names imply")
    func thresholdsOrdered() {
        #expect(SpokenForms.plausibleScore < SpokenForms.confidentScore)
        #expect(SpokenForms.plausibleScore > 0)
        #expect(SpokenForms.confidentScore < 1)
    }

    @Test("nothing matched is nothing claimed")
    func noneIsEmpty() {
        let none = SpokenForms.Match.none
        #expect(none.score == 0)
        #expect(none.spokenTokens.isEmpty)
        #expect(none.isPlausible == false)
        #expect(none.isConfident == false)
    }

    /// The cap is not a suggestion. A name with three acronym runs and two digit runs
    /// generates a product, and the product is what the prompt budget is spent on.
    @Test("a name that could generate a hundred variants is still capped")
    func variantsAreCapped() {
        let awkward = "src/api/v2/HTTPAPIClientV404Base.tsx"
        #expect(SpokenForms.variants(of: awkward).count <= SpokenForms.variantLimit)
        #expect(SpokenForms.variants(of: awkward, limit: 3).count == 3)
        #expect(SpokenForms.variants(of: awkward, limit: 0).isEmpty)
    }

    @Test("a name with nothing sayable in it produces nothing")
    func emptyNames() {
        #expect(SpokenForms.variants(of: "").isEmpty)
        #expect(SpokenForms.variants(of: "///").isEmpty)
        #expect(SpokenForms.biasPhrase(for: "") == nil)
        #expect(SpokenForms.score(spoken: "anything at all", against: "").score == 0)
        #expect(SpokenForms.bestMatch(of: "", in: "anything at all").score == 0)
    }

    /// The reason `biasPhrase` exists rather than `variants(of:).first`: an ASR context list
    /// of common words is worse than an empty one, and the budget is 40 slots for everything.
    @Test("bias budget is never spent on a common word or a two-letter name")
    func biasPhraseRejects() {
        for name in ["index.ts", "main.py", "app.tsx", "utils.ts", "config.json", "id.ts", "a.ts"] {
            #expect(SpokenForms.biasPhrase(for: name) == nil, "\(name) should not spend bias budget")
        }
        #expect(SpokenForms.biasPhrase(for: "loginHandler.tsx") == "login handler")
        #expect(SpokenForms.biasPhrase(for: "APIClient.swift") == "API client")
    }

    /// A dictionary long enough to fill the budget on its own is the case that matters: the
    /// harvest must lose, silently and completely, rather than pushing a typed entry out.
    @Test("a full dictionary keeps every slot")
    func harvestNeverEvictsTheDictionary() {
        let dictionary = (0..<60).map { "Word\($0)" }
        let harvested = (0..<40).map { "Harvested\($0)" }
        let merged = SpokenForms.mergedBiasPhrases(dictionary: dictionary, harvested: harvested)

        #expect(merged.count == DictionaryCorrector.biasLimit)
        #expect(merged == Array(dictionary.prefix(DictionaryCorrector.biasLimit)))
        #expect(merged.contains { $0.hasPrefix("Harvested") } == false)
    }

    @Test("the harvested share is never exceeded, whatever the room")
    func harvestedShareHolds() {
        let harvested = (0..<40).map { "Harvested\($0)" }
        let merged = SpokenForms.mergedBiasPhrases(dictionary: [], harvested: harvested)

        #expect(merged.count == SpokenForms.harvestedBiasShare)
        #expect(merged.first == "Harvested0")
        #expect(merged.count < DictionaryCorrector.biasLimit)
    }

    /// Scoring a paragraph against 200 candidates is the real workload, and the six-token
    /// window is what keeps a long utterance from being scored as one enormous phrase. It is
    /// not what makes the workload cheap — the cost is ~6N alignments per candidate either way,
    /// and what made it affordable was hoisting the per-name and per-token work out of the
    /// window loop. This asserts the shape of the cost rather than a wall-clock time, which no
    /// CI runner can promise.
    @Test("a name is scored against a paragraph without walking the whole paragraph as one phrase")
    func windowsAreBounded() {
        let sentence = Array(repeating: "word", count: 40).joined(separator: " ")
            + " open the login handler file"
        let match = SpokenForms.bestMatch(of: "loginHandler.tsx", in: sentence)

        #expect(match.isConfident)
        #expect(match.spokenTokens.count <= 6)
        // Scored as one phrase instead, the forty leading words would take the leftover
        // penalty all the way to zero — which is exactly why `bestMatch` windows.
        #expect(SpokenForms.score(spoken: sentence, against: "loginHandler.tsx").score == 0)
    }

    /// The tokenizing-once overload has to be indistinguishable from the convenience one.
    ///
    /// It exists purely so a caller with 200 candidates pays for one pass over the transcript
    /// instead of 200, and `ScreenContext.narrowed(toMentionsIn:)` is that caller — in the app
    /// target, where nothing can test it. If the two ever disagree, the names in a cleanup
    /// prompt stop being the names the vectors describe, and every `bestMatches` case above
    /// would still pass, because they all go through the string overload.
    @Test("scoring against a pre-tokenized transcript is the same as scoring against the string")
    func heardMatchesTheStringOverload() throws {
        let vectors = try Self.load()
        for testCase in vectors.bestMatches {
            let heard = SpokenForms.Heard(testCase.transcript)
            let viaHeard = SpokenForms.bestMatch(of: testCase.name, in: heard)
            let viaString = SpokenForms.bestMatch(of: testCase.name, in: testCase.transcript)
            #expect(viaHeard == viaString, "\(testCase.note)")
        }
    }
}
