import Foundation

/// Experimental transport for the existing plan, not a second renderer. Block ends
/// imply block starts; each list item carries its own strip count and spoken evidence.
/// The grammar binds endpoints to this passage and enforces monotonic coverage and
/// at least two list items. Existing plan limits and semantic checks still apply.
enum StructurePlanWire {
    struct Document: Decodable {
        let blocks: [Block]
    }

    struct Block: Decodable {
        let kind: StructurePlan.Kind
        let to: Int
        let items: [Item]
        enum CodingKeys: String, CodingKey { case kind, to, items }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(StructurePlan.Kind.self, forKey: .kind)
            to = try values.decode(Int.self, forKey: .to)
            if kind.isList {
                items = try values.decode([Item].self, forKey: .items)
            } else {
                items = []
            }
        }
    }

    struct Item: Decodable {
        let start: Int
        let strip: Int
        let quote: String
    }

    enum Failure: Error { case extraFields, invalidPlan }

    static func decode(_ json: String, sentenceCount: Int) throws -> StructurePlan {
        let document = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        var start = 1
        let blocks = document.blocks.map { block in
            defer { start = block.to + 1 }
            return StructurePlan.Block(kind: block.kind, from: start, to: block.to,
                itemStarts: block.items.map(\.start), stripWords: block.items.map(\.strip),
                announcerQuotes: block.items.map(\.quote))
        }
        let plan = StructurePlan(blocks: blocks)
        guard plan.rejection(sentenceCount: sentenceCount) == nil else { throw Failure.invalidPlan }
        return plan
    }

    // Preserve the existing semantic instructions. Only their output representation
    // changes; the first transport trial's shorter semantics missed French items.
    static let system = StructurePlanPrompt.system + """


        Use this COMPACT representation instead of separate parallel arrays:
        {"blocks":[...]}. Every block has "kind" and "to" (inclusive last sentence).
        Block starts are implicit: sentence 1 or the preceding block's "to" plus 1.
        ONLY list blocks also have "items", BEFORE "to". Each item has "start"
        (the itemStarts sentence number), "strip" (stripWords value), and "quote"
        (announcerQuotes value). Item starts increase strictly; the first equals the
        block start. Keep the announcement of the FIRST ITEM as well as later ones.
        Non-list blocks omit items. Never emit from or the old parallel arrays.
        Example, first item spans sentences 1/2 and second starts at 3:
        {"blocks":[{"kind":"numbered","items":[{"start":1,"strip":1,"quote":"First,"},{"start":3,"strip":1,"quote":"Second,"}],"to":3}]}
        Ordinary prose: {"blocks":[{"kind":"prose","to":4}]}.
        """

    static func grammar(sentenceCount n: Int) -> GBNFGrammar {
        precondition((1...80).contains(n))
        return .composed { builder in
            let quote = builder.rule(for: .string(maxLength: 80), name: "announcement")
            let strip = "(" + (0...StructurePlan.Limits.maxStripWords)
                .map { GBNFBuilder.literal(String($0)) }.joined(separator: " | ") + ")"
            builder.add("item-meta", "ws \",\" ws \"\\\"strip\\\"\" ws \":\" ws \(strip) ws \",\" ws \"\\\"quote\\\"\" ws \":\" ws \(quote) ws \"}\" ws")
            for start in 0..<n {
                var ordinary: [String] = []
                var first: [String] = []
                var subsequent: [String] = []
                for end in (start + 1)...n {
                    let number = GBNFBuilder.literal(String(end))
                    ordinary.append("\(number) ws \"}\" ws after-\(end)")
                    let item = "\"{\" ws \"\\\"start\\\"\" ws \":\" ws \(number) item-meta"
                    if end < n {
                        if end == start + 1 { first.append("\(item) \",\" ws items-\(end)") }
                        subsequent.append("\(item) (\",\" ws items-\(end) | \"]\" ws \",\" ws \"\\\"to\\\"\" ws \":\" ws end-\(end - 1))")
                    } else {
                        subsequent.append("\(item) \"]\" ws \",\" ws \"\\\"to\\\"\" ws \":\" ws end-\(end - 1)")
                    }
                }
                builder.add("end-\(start)", "(" + ordinary.joined(separator: " | ") + ")")
                builder.add("items-\(start)", "(" + subsequent.joined(separator: " | ") + ")")
                var choices = ["\"{\" ws \"\\\"kind\\\"\" ws \":\" ws (\"\\\"prose\\\"\" | \"\\\"quote\\\"\" | \"\\\"code\\\"\") ws \",\" ws \"\\\"to\\\"\" ws \":\" ws end-\(start)"]
                if !first.isEmpty {
                    builder.add("first-\(start)", "(" + first.joined(separator: " | ") + ")")
                    choices.append("\"{\" ws \"\\\"kind\\\"\" ws \":\" ws (\"\\\"numbered\\\"\" | \"\\\"bulleted\\\"\") ws \",\" ws \"\\\"items\\\"\" ws \":\" ws \"[\" ws first-\(start)")
                }
                builder.add("blocks-\(start)", "(" + choices.joined(separator: " | ") + ")")
                if start > 0 { builder.add("after-\(start)", "\",\" ws blocks-\(start)") }
            }
            builder.add("after-\(n)", "\"]\" ws \"}\" ws")
            return "ws \"{\" ws \"\\\"blocks\\\"\" ws \":\" ws \"[\" ws blocks-0"
        }
    }

    static func selfTestFailures() async -> [String] {
        var failures: [String] = []
        // Original producer accepts overlapping/out-of-range/single-item plans.
        // Pin that contract independently of the new adapter and decoder grammar.
        let invalidFull = """
            {"blocks":[{"kind":"numbered","from":1,"to":3,"itemStarts":[1],"stripWords":[0],"announcerQuotes":[""]}]}
            """
        if !StructurePlanPrompt.grammar().matches(invalidFull)
            || (try? JSONDecoder().decode(StructurePlan.self, from: Data(invalidFull.utf8)))?
                .rejection(sentenceCount: 3) == nil {
            failures.append("original one-item grammar regression was not reproduced")
        }
        let good = [
            (1, #"{"blocks":[{"kind":"prose","to":1}]}"#),
            (3, #"{"blocks":[{"kind":"quote","to":1},{"kind":"code","to":2},{"kind":"prose","to":3}]}"#),
            (4, #"{"blocks":[{"kind":"numbered","items":[{"start":1,"strip":1,"quote":"First"},{"start":3,"strip":0,"quote":""}],"to":4}]}"#),
            (4, #"{"blocks":[{"kind":"prose","to":1},{"kind":"bulleted","items":[{"start":2,"strip":0,"quote":"D'abord"},{"start":3,"strip":1,"quote":"Ensuite"},{"start":4,"strip":2,"quote":"Pour finir"}],"to":4}]}"#),
            (5, #"{"blocks":[{"kind":"prose","to":1},{"kind":"numbered","items":[{"start":2,"strip":0,"quote":""},{"start":3,"strip":3,"quote":"The second thing"},{"start":4,"strip":2,"quote":"Third thing"}],"to":4},{"kind":"prose","to":5}]}"#),
        ]
        let bad = [
            #"{"blocks":[]}"#,
            #"{"blocks":[{"kind":"prose","to":2}]}"#,
            #"{"blocks":[{"kind":"prose","to":4}]}"#,
            #"{"blocks":[{"kind":"prose","to":0},{"kind":"prose","to":3}]}"#,
            #"{"blocks":[{"kind":"prose","to":2},{"kind":"quote","to":1},{"kind":"prose","to":3}]}"#,
            #"{"blocks":[{"kind":"numbered","items":[{"start":1,"strip":0,"quote":""}],"to":3}]}"#,
            #"{"blocks":[{"kind":"bulleted","items":[{"start":2,"strip":0,"quote":""},{"start":1,"strip":0,"quote":""}],"to":3}]}"#,
            #"{"blocks":[{"kind":"numbered","items":[{"start":1,"strip":9,"quote":"First"},{"start":3,"strip":0,"quote":""}],"to":3}]}"#,
            #"{"blocks":[{"kind":"numbered","items":[{"start":1,"strip":0,"quote":""},{"start":1,"strip":0,"quote":""},{"start":3,"strip":0,"quote":""}],"to":3}]}"#,
            #"{"blocks":[{"kind":"numbered","items":[{"start":1,"strip":0,"quote":""},{"start":3,"strip":0,"quote":""}],"to":2},{"kind":"prose","to":3}]}"#,
        ]
        let three = grammar(sentenceCount: 3)
        for json in bad {
            if three.matches(json) || (try? decode(json, sentenceCount: 3)) != nil {
                failures.append("compact layout admits broken original geometry/shape: \(json)")
            }
        }
        if let plan = try? decode(good[3].1, sentenceCount: 4) {
            let expected = StructurePlan(blocks: [
                .init(kind: .prose, from: 1, to: 1),
                .init(kind: .bulleted, from: 2, to: 4, itemStarts: [2,3,4],
                      stripWords: [0,1,2], announcerQuotes: ["D'abord","Ensuite","Pour finir"]),
            ])
            if plan != expected { failures.append("compact adapter changes existing plan fields") }
        }
        // Actual planner/provider boundary: grammar, prompt and adapter must agree.
        struct Provider: LLMProvider {
            let text: String
            var id: LLMProviderID { .appLLM }
            var contextTokens: Int { 4096 }
            var unavailableReason: String? { nil }
            func countTokens(_ text: String) async throws -> Int { text.count }
            func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
                throw Failure.invalidPlan
            }
            func complete(system: String, user: String, maxTokens: Int,
                          grammar: GBNFGrammar) async throws -> LLMCompletion {
                guard system == StructurePlanWire.system, grammar.matches(text), maxTokens == 500
                else { throw Failure.invalidPlan }
                return LLMCompletion(text: text, generatedTokens: 1, duration: 0)
            }
        }
        let outcome = await LLMStructurePlanner(provider: Provider(text: good[3].1),
            usesCompactWire: true).plan(for: ["J'ai trois points pour toi.",
                "D'abord on règle la facturation.", "Ensuite on déplace la réunion de jeudi.",
                "Pour finir on appelle le comptable."], deadline: nil)
        if outcome.plan == nil || outcome.rejection != nil {
            failures.append("actual compact planner/provider consumer did not decode the plan")
        }
        return failures
    }
}
