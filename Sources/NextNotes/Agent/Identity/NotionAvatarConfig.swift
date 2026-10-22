import Foundation

/// Numeric part indices for a Notion-style avatar.
///
/// Matches the config shape used by [react-notion-avatar](https://github.com/zonemeen/react-notion-avatar)
/// and [Mayandev/notion-avatar](https://github.com/Mayandev/notion-avatar): each field is an
/// index into `Resources/NotionAvatar/<part>/<index>.svg`. Index `0` is empty for optional
/// layers (hair, glasses, accessories, beard, details).
///
/// Illustration assets are Felix Wong’s Noto avatar pack (CC0); see
/// `Resources/NotionAvatar/ATTRIBUTION.md`.
struct NotionAvatarConfig: Codable, Equatable, Sendable, Hashable {
    var face: Int
    var eyes: Int
    var eyebrows: Int
    var glasses: Int
    var hair: Int
    var mouth: Int
    var nose: Int
    var accessories: Int
    var beard: Int
    var details: Int

    /// Inclusive maxima — `0...max` is valid, matching Mayandev’s `AvatarStyleCount`.
    enum Part: String, CaseIterable, Identifiable, Sendable {
        case face, nose, mouth, eyes, eyebrows, glasses, hair, accessories, details, beard

        var id: String { rawValue }

        /// Folder name under `Resources/NotionAvatar/`.
        var directory: String { rawValue }

        var displayName: String {
            switch self {
            case .face: "Face"
            case .nose: "Nose"
            case .mouth: "Mouth"
            case .eyes: "Eyes"
            case .eyebrows: "Eyebrows"
            case .glasses: "Glasses"
            case .hair: "Hair"
            case .accessories: "Accessories"
            case .details: "Details"
            case .beard: "Beard"
            }
        }

        /// Highest index that ships in the vendored preview set.
        var maxIndex: Int {
            switch self {
            case .face: 15
            case .nose: 13
            case .mouth: 19
            case .eyes: 13
            case .eyebrows: 15
            case .glasses: 14
            case .hair: 58
            case .accessories: 14
            case .details: 13
            case .beard: 16
            }
        }

        /// Draw order when compositing into one 1080×1080 SVG (Mayandev’s production order).
        static let drawOrder: [Part] = [
            .face, .nose, .mouth, .eyes, .eyebrows, .glasses, .hair, .accessories, .details, .beard,
        ]
    }

    static let `default` = NotionAvatarConfig(
        face: 4, eyes: 3, eyebrows: 3, glasses: 0, hair: 12,
        mouth: 2, nose: 3, accessories: 0, beard: 0, details: 0
    )

    subscript(_ part: Part) -> Int {
        get {
            switch part {
            case .face: face
            case .nose: nose
            case .mouth: mouth
            case .eyes: eyes
            case .eyebrows: eyebrows
            case .glasses: glasses
            case .hair: hair
            case .accessories: accessories
            case .details: details
            case .beard: beard
            }
        }
        set {
            let clamped = max(0, min(newValue, part.maxIndex))
            switch part {
            case .face: face = clamped
            case .nose: nose = clamped
            case .mouth: mouth = clamped
            case .eyes: eyes = clamped
            case .eyebrows: eyebrows = clamped
            case .glasses: glasses = clamped
            case .hair: hair = clamped
            case .accessories: accessories = clamped
            case .details: details = clamped
            case .beard: beard = clamped
            }
        }
    }

    /// Deterministic face from a name: same name, same face, every launch.
    /// Stable fold (never `hashValue`, which is seeded per process) over the same
    /// shape as `random()`, minus the coin flips — optional layers appear for some
    /// names (every fourth gets glasses, every sixth a beard) rather than at random.
    /// Empty names fall back to `.default`; the caller decides when a typed name
    /// earns a face, never this function.
    static func forName(_ name: String) -> NotionAvatarConfig {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .default }
        var fold = 0
        for scalar in trimmed.lowercased().unicodeScalars {
            fold = (fold &* 31 &+ Int(scalar.value)) % 1_000_003
        }
        func pick(_ max: Int, _ salt: Int) -> Int {
            (fold &* (salt &* 2_654_435_761 &+ 1)) % 1_000_003 % (max + 1)
        }
        var config = NotionAvatarConfig(
            face: pick(Part.face.maxIndex, 1),
            eyes: pick(Part.eyes.maxIndex, 2),
            eyebrows: pick(Part.eyebrows.maxIndex, 3),
            glasses: 0,
            hair: pick(Part.hair.maxIndex, 4),
            mouth: pick(Part.mouth.maxIndex, 5),
            nose: pick(Part.nose.maxIndex, 6),
            accessories: 0,
            beard: 0,
            details: 0
        )
        if fold % 4 == 0 { config.glasses = pick(Part.glasses.maxIndex, 7) }
        if fold % 6 == 0 { config.beard = pick(Part.beard.maxIndex, 8) }
        return config
    }

    /// Random face with optional layers cleared (same bias as react-notion-avatar’s
    /// `getRandomConfig`).
    static func random() -> NotionAvatarConfig {
        var config = NotionAvatarConfig(
            face: Int.random(in: 0...Part.face.maxIndex),
            eyes: Int.random(in: 0...Part.eyes.maxIndex),
            eyebrows: Int.random(in: 0...Part.eyebrows.maxIndex),
            glasses: Int.random(in: 0...Part.glasses.maxIndex),
            hair: Int.random(in: 0...Part.hair.maxIndex),
            mouth: Int.random(in: 0...Part.mouth.maxIndex),
            nose: Int.random(in: 0...Part.nose.maxIndex),
            accessories: 0,
            beard: 0,
            details: 0
        )
        // Occasionally keep a beard / accessory / detail.
        if Bool.random() { config.beard = Int.random(in: 0...Part.beard.maxIndex) }
        if Bool.random() { config.accessories = Int.random(in: 0...Part.accessories.maxIndex) }
        if Bool.random() { config.details = Int.random(in: 0...Part.details.maxIndex) }
        return config
    }
}
