import Foundation

/// Experimental transport for the existing plan, not a second renderer. Endpoints
/// imply starts; each list item carries its own strip count and spoken evidence.
/// The grammar binds endpoints to this passage and enforces monotonic coverage and
/// at least two list items. Existing plan limits and semantic checks still apply.
enum StructurePlanWire {
    struct Document: Decodable {
        let blocks: [Block]
    }

    struct Block: Decodable {
        let kind: StructurePlan.Kind
        let end: Int
        let items: [Item]

        init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            kind = try values.decode(StructurePlan.Kind.self)
            if kind.isList {
                items = try values.decode([Item].self)
                end = items.last?.end ?? 0
            } else {
                end = try values.decode(Int.self)
                items = []
            }
            guard values.isAtEnd else { throw Failure.extraFields }
        }
    }

    struct Item: Decodable {
        let end: Int
        let strip: Int
        let announcement: String

        init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            end = try values.decode(Int.self)
            strip = try values.decode(Int.self)
            announcement = try values.decode(String.self)
            guard values.isAtEnd else { throw Failure.extraFields }
        }
    }

    enum Failure: Error { case extraFields, invalidPlan }

    static func decode(_ json: String, sentenceCount: Int) throws -> StructurePlan {
        let document = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        var start = 1
        let blocks = document.blocks.map { block in
            var itemStart = start
            let starts = block.items.map { item in
                defer { itemStart = item.end + 1 }
                return itemStart
            }
            defer { start = block.end + 1 }
            return StructurePlan.Block(kind: block.kind, from: start, to: block.end,
                itemStarts: starts, stripWords: block.items.map(\.strip),
                announcerQuotes: block.items.map(\.announcement))
        }
        let plan = StructurePlan(blocks: blocks)
        guard plan.rejection(sentenceCount: sentenceCount) == nil else { throw Failure.invalidPlan }
        return plan
    }

    static let system = """
        You arrange dictated speech without rewriting, translating or summarising any words.
        Return only {"blocks":[...]} using the compact format below.
        Every number is an INCLUSIVE END sentence number. Starts follow the previous end.
        Cover all sentences in order, exactly once. The final end equals the sentence count.

        Ordinary block: ["prose",end], ["quote",end], or ["code",end].
        List block: ["numbered",[[end,strip,"announcement"],...]] or
        ["bulleted",[[end,strip,"announcement"],...]]. Each triple describes one item.
        An item may span several sentences. A list has at least two items.
        strip is 0 to 8 opening words that only announce the item, never content.
        announcement is the exact spoken announcement, at most 8 words in its original
        language, or "" when absent. Do not copy content into announcement. Use strip 0
        when there is no announcement. Keep introductions and closing remarks in prose.

        Use numbered for counted points in any language, including a promised number of
        points whose first item has no ordinal: "a few things", "j'ai trois points".
        "The second thing", "Third thing", "Premièrement", "Deuxièmement", "Enfin"
        announce items. "D'abord", "Ensuite", "Pour finir" may introduce uncounted items.
        Use bulleted for parallel announced items without counting. Bare imperatives and
        ordinary prose mentioning "the first time" are not lists. Use prose for them.
        Split prose into paragraphs only at a clear subject change. Quote/code retain the
        speaker's own words. Never invent an announcement or turn an introduction into an item.

        Example with intro 1, three items 2/3/4, closing 5:
        {"blocks":[["prose",1],["numbered",[[2,0,""],[3,3,"The second thing"],[4,2,"Third thing"]]],["prose",5]]}
        Example with a two-sentence first item and another item ending at 6:
        {"blocks":[["numbered",[[2,1,"First"],[6,1,"Second"]]]]}
        Example with ordinary prose only: {"blocks":[["prose",5]]}.
        """

    static func grammar(sentenceCount n: Int) -> GBNFGrammar {
        precondition((1...80).contains(n))
        return .composed { builder in
            let quote = builder.rule(for: .string(maxLength: 80), name: "announcement")
            let strip = "(" + (0...StructurePlan.Limits.maxStripWords)
                .map { GBNFBuilder.literal(String($0)) }.joined(separator: " | ") + ")"
            builder.add("item-meta", "ws \",\" ws \(strip) ws \",\" ws \(quote) ws \"]\" ws")
            for start in 0..<n {
                var ordinary: [String] = []
                var first: [String] = []
                var subsequent: [String] = []
                for end in (start + 1)...n {
                    let number = GBNFBuilder.literal(String(end))
                    ordinary.append("\(number) ws \"]\" ws after-\(end)")
                    let item = "\"[\" ws \(number) item-meta"
                    if end < n {
                        first.append("\(item) \",\" ws items-\(end)")
                        subsequent.append("\(item) (\",\" ws items-\(end) | \"]\" ws \"]\" ws after-\(end))")
                    } else {
                        subsequent.append("\(item) \"]\" ws \"]\" ws after-\(end)")
                    }
                }
                builder.add("end-\(start)", "(" + ordinary.joined(separator: " | ") + ")")
                builder.add("items-\(start)", "(" + subsequent.joined(separator: " | ") + ")")
                var choices = ["\"[\" ws (\"\\\"prose\\\"\" | \"\\\"quote\\\"\" | \"\\\"code\\\"\") ws \",\" ws end-\(start)"]
                if !first.isEmpty {
                    builder.add("first-\(start)", "(" + first.joined(separator: " | ") + ")")
                    choices.append("\"[\" ws (\"\\\"numbered\\\"\" | \"\\\"bulleted\\\"\") ws \",\" ws \"[\" ws first-\(start)")
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
            (1, #"{"blocks":[["prose",1]]}"#),
            (3, #"{"blocks":[["quote",1],["code",2],["prose",3]]}"#),
            (4, #"{"blocks":[["numbered",[[2,1,"First"],[4,0,""]]]]}"#),
            (4, #"{"blocks":[["prose",1],["bulleted",[[2,0,"D'abord"],[3,1,"Ensuite"],[4,2,"Pour finir"]]]]}"#),
            (5, #"{"blocks":[["prose",1],["numbered",[[2,0,""] ,[3,3,"The second thing"],[4,2,"Third thing"]]],["prose",5]]}"#),
        ]
        for (count, json) in good {
            let grammar = grammar(sentenceCount: count)
            if !grammar.structuralProblems().isEmpty || !grammar.matches(json)
                || (try? decode(json, sentenceCount: count)) == nil {
                failures.append("compact layout rejects valid feature plan: \(json)")
            }
        }
        let bad = [
            #"{"blocks":[]}"#,
            #"{"blocks":[["prose",2]]}"#,
            #"{"blocks":[["prose",4]]}"#,
            #"{"blocks":[["prose",0],["prose",3]]}"#,
            #"{"blocks":[["prose",2],["quote",1],["prose",3]]}"#,
            #"{"blocks":[["numbered",[[3,0,""]]]]}"#,
            #"{"blocks":[["bulleted",[[2,0,""],[1,0,""],[3,0,""]]]]}"#,
            #"{"blocks":[["numbered",[[1,9,"First"],[3,0,""]]]]}"#,
            #"{"blocks":[["numbered",[[1,0,""],[1,0,""],[3,0,""]]]]}"#,
            #"{"blocks":[["prose",3,[]]]}"#,
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
