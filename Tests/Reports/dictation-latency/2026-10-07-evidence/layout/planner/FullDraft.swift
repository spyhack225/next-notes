import Foundation
import FoundationModels

/// The plan, in the shape Apple's guided generation can be asked for directly.
///
/// A separate type from `StructurePlan` on purpose. `@Generable` describes what the sampler
/// is allowed to emit; `StructurePlan` describes what this app is willing to render, and the
/// step between them is where a plan is checked. Collapsing the two would mean the validator
/// and the schema could only ever agree.
@Generable(description: "A layout plan for a passage of dictated speech. Blocks must cover every sentence exactly once, in order.")
struct StructurePlanDraft {

    @Generable(description: "What to do with one run of consecutive sentences.")
    enum Kind {
        case prose
        case numbered
        case bulleted
        case quote
        case code
    }

    @Generable(description: "One run of consecutive sentences.")
    struct Block {
        @Guide(description: "prose for ordinary paragraphs; numbered when the speaker counted things out loud; bulleted for an uncounted list; quote for a spoken quotation; code for a dictated command.")
        var kind: Kind

        @Guide(description: "The first sentence number in this block, 1-based.")
        var from: Int

        @Guide(description: "The last sentence number in this block, 1-based and not before 'from'.")
        var to: Int

        @Guide(description: "For numbered or bulleted only: the sentence number each item begins on, in order, starting with 'from'. At least two. Leave empty for every other kind.")
        var itemStarts: [Int]

        @Guide(description: "For numbered or bulleted only: for each item, how many words at the start of its first sentence are only the spoken announcement and not content. 0 when the item starts straight into content, never more than 8. Leave empty for every other kind.")
        var stripWords: [Int]

        @Guide(description: "For numbered or bulleted only: for each item, the exact spoken words announcing it, quoted word for word in whatever language was spoken — 'The second thing,', 'Premièrement,'. Empty string when the item starts straight into content. Never more than 8 words. Leave empty for every other kind.")
        var announcerQuotes: [String]
    }

    @Guide(description: "The blocks, in sentence order, covering every sentence exactly once.")
    var blocks: [Block]
}

extension StructurePlanDraft {
    var plan: StructurePlan {
        StructurePlan(blocks: blocks.map { block in
            StructurePlan.Block(
                kind: block.kind.kind,
                from: block.from,
                to: block.to,
                itemStarts: block.itemStarts,
                stripWords: block.stripWords,
                announcerQuotes: block.announcerQuotes
            )
        })
    }
}

extension StructurePlanDraft.Kind {
    var kind: StructurePlan.Kind {
        switch self {
        case .prose: .prose
        case .numbered: .numbered
        case .bulleted: .bulleted
        case .quote: .quote
        case .code: .code
        }
    }
}

