import Foundation
import FoundationModels

@Generable(description: "A layout plan for a passage of dictated speech. Blocks must cover every sentence exactly once, in order.")
struct TypedDraft {
    @Generable(description: "One run of consecutive sentences. Prose is ordinary paragraphs; a numbered or bulleted block is the whole list, containing at least two items, never one block per item.")
    enum Block {
        case prose(Span)
        case numbered(List)
        case bulleted(List)
        case quote(Span)
        case code(Span)
    }
    @Generable(description: "A contiguous run of numbered sentences.")
    struct Span {
        @Guide(description: "The first sentence number, 1-based.", .range(1...80))
        var from: Int
        @Guide(description: "The last sentence number, inclusive, not before from.", .range(1...80))
        var to: Int
    }
    @Generable(description: "One complete list, with all its items in order.")
    struct List {
        @Guide(description: "The first sentence number in this list, 1-based.", .range(1...80))
        var from: Int
        @Guide(description: "The last sentence number in this list, inclusive.", .range(1...80))
        var to: Int
        @Guide(description: "The sentence number each item begins on, in order, starting with from. At least two items in this same block.", .count(2...24), .element(.range(1...80)))
        var itemStarts: [Int]
        @Guide(description: "For each item, how many words at the start of its first sentence are only the spoken announcement and not content. 0 when it starts straight into content, never more than 8.", .maximumCount(24), .element(.range(0...8)))
        var stripWords: [Int]
        @Guide(description: "For each item, the exact spoken words announcing it, quoted word for word in whatever language was spoken. Empty string when it starts straight into content. Never more than 8 words.", .maximumCount(24))
        var announcerQuotes: [String]
    }
    @Guide(description: "The blocks in sentence order, covering every sentence exactly once.", .count(1...40))
    var blocks: [Block]

    var plan: StructurePlan {
        StructurePlan(blocks: blocks.map { block in
            switch block {
            case .prose(let x): .init(kind: .prose, from: x.from, to: x.to)
            case .quote(let x): .init(kind: .quote, from: x.from, to: x.to)
            case .code(let x): .init(kind: .code, from: x.from, to: x.to)
            case .numbered(let x): .init(kind: .numbered, from: x.from, to: x.to, itemStarts: x.itemStarts, stripWords: x.stripWords, announcerQuotes: x.announcerQuotes)
            case .bulleted(let x): .init(kind: .bulleted, from: x.from, to: x.to, itemStarts: x.itemStarts, stripWords: x.stripWords, announcerQuotes: x.announcerQuotes)
            }
        })
    }
}
