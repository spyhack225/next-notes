import AppKit
import Foundation

/// The avatar split into the four layers a face is animated with, in draw order.
///
/// The same split the SVG draw order already describes (`face, nose, mouth, eyes, eyebrows,
/// glasses, hair, …`), collapsed into the smallest number of bitmaps that can move
/// independently: everything under the eyes, the eyes, the brows, and everything over them.
/// Registration is free because every part is a 1080×1080 canvas — the layers stack
/// exactly where the flattened composite drew them.
///
/// A blink compresses the eyes layer about the canvas centre, and that is measured rather
/// than assumed: every eye part in the vendored set centres its ink on y = 540 (`eyes/1`
/// translates to 509 with a 31pt radius, `eyes/7` spans 516…564, `eyes/3` sits at 540.7),
/// so compressing the layer about the middle closes both eyes in place.
struct NotionAvatarLayers {
    let under: NSImage
    let eyes: NSImage
    let brows: NSImage
    let over: NSImage
}

/// Builds a layered Notion-style avatar SVG from vendored preview parts and rasterises it.
///
/// Parts live at `Resources/NotionAvatar/<part>/<index>.svg` (copied into the app bundle by
/// `make app`). Each file is already a 1080×1080 SVG; composition strips the outer `<svg>`
/// and nests groups — the same approach as Mayandev/notion-avatar’s preview pipeline.
@MainActor
enum NotionAvatarRenderer {
    private static let cache = NSCache<NSString, NSImage>()
    private static let layerCache = NSCache<NSString, LayersBox>()

    /// `NSCache` holds objects, and the four layers are a value.
    private final class LayersBox {
        let layers: NotionAvatarLayers
        init(_ layers: NotionAvatarLayers) { self.layers = layers }
    }

    /// Rasterise `config` to an `NSImage` of the given side length (points).
    static func image(for config: NotionAvatarConfig, side: CGFloat) -> NSImage? {
        let key = cacheKey(config, side: side) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let svg = svgString(for: config),
              let image = rasterise(svg: svg, side: side) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The same face, split for animation. One bitmap per movable layer.
    static func layers(for config: NotionAvatarConfig, side: CGFloat) -> NotionAvatarLayers? {
        let key = "layers-\(cacheKey(config, side: side))" as NSString
        if let cached = layerCache.object(forKey: key) { return cached.layers }
        var images: [NSImage] = []
        for group in layerGroups {
            guard let svg = compose(parts: group, config: config),
                  let image = rasterise(svg: svg, side: side) else { return nil }
            images.append(image)
        }
        let layers = NotionAvatarLayers(
            under: images[0], eyes: images[1], brows: images[2], over: images[3]
        )
        layerCache.setObject(LayersBox(layers), forKey: key)
        return layers
    }

    /// Draw order preserved, one group per movable layer. Anything missing from the vendored
    /// set skips its own layer rather than failing the face — `layers(for:)` then returns nil
    /// only when *nothing* could be composed, which is the case `AgentAvatarView` falls back
    /// to the orb on.
    private static let layerGroups: [[NotionAvatarConfig.Part]] = [
        [.face, .nose, .mouth],
        [.eyes],
        [.eyebrows],
        [.glasses, .hair, .accessories, .details, .beard],
    ]

    private static func cacheKey(_ config: NotionAvatarConfig, side: CGFloat) -> String {
        [
            "\(config.face)", "\(config.eyes)", "\(config.eyebrows)", "\(config.glasses)",
            "\(config.hair)", "\(config.mouth)", "\(config.nose)", "\(config.accessories)",
            "\(config.beard)", "\(config.details)", "\(Int(side))",
        ].joined(separator: "-")
    }

    static func svgString(for config: NotionAvatarConfig) -> String? {
        compose(parts: NotionAvatarConfig.Part.drawOrder, config: config)
    }

    /// Compose `parts`, in the order given, into one 1080×1080 SVG.
    private static func compose(parts: [NotionAvatarConfig.Part], config: NotionAvatarConfig) -> String? {
        var groups: [String] = []
        for part in parts {
            guard let inner = partInnerSVG(part: part, index: config[part]) else {
                // Missing asset: skip that layer rather than failing the whole face.
                continue
            }
            let faceFill = part == .face ? " fill=\"#ffffff\"" : ""
            groups.append("<g id=\"notion-avatar-\(part.rawValue)\"\(faceFill)>\(inner)</g>")
        }
        guard !groups.isEmpty else { return nil }
        return """
            <svg viewBox="0 0 1080 1080" width="1080" height="1080" fill="none" \
            xmlns="http://www.w3.org/2000/svg">\
            \(groups.joined())\
            </svg>
            """
    }

    // MARK: - Bundle lookup

    /// Preview SVG directory: app bundle first, then the repo `Resources/` when running a
    /// bare SwiftPM binary from the source tree.
    static func partsDirectory() -> URL? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("NotionAvatar", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Bare `make build` binary: walk up from the executable toward the repo root.
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("Resources/NotionAvatar", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func partURL(part: NotionAvatarConfig.Part, index: Int) -> URL? {
        partsDirectory()?
            .appendingPathComponent(part.directory, isDirectory: true)
            .appendingPathComponent("\(index).svg")
    }

    private static func partInnerSVG(part: NotionAvatarConfig.Part, index: Int) -> String? {
        guard let url = partURL(part: part, index: index),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return stripOuterSVG(raw)
    }

    /// Drop the outer `<svg…>` / `</svg>` so the content can nest inside a combined canvas.
    private static func stripOuterSVG(_ raw: String) -> String {
        var text = raw
        if let open = text.range(of: #"<svg[^>]*>"#, options: .regularExpression) {
            text.removeSubrange(open)
        }
        if let close = text.range(of: "</svg>", options: [.backwards, .caseInsensitive]) {
            text.removeSubrange(close)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rasterise

    private static func rasterise(svg: String, side: CGFloat) -> NSImage? {
        guard let data = svg.data(using: .utf8) else { return nil }
        // ImageIO is happiest with a file URL for SVG; a short-lived temp file is fine.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-avatar-\(UUID().uuidString).svg")
        do {
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let source = NSImage(contentsOf: url) else { return nil }
            let target = NSImage(size: NSSize(width: side, height: side))
            target.lockFocus()
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: target.size).fill()
            source.draw(
                in: NSRect(origin: .zero, size: target.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            target.unlockFocus()
            return target
        } catch {
            return nil
        }
    }
}
