import AppKit
import Foundation

/// Builds a layered Notion-style avatar SVG from vendored preview parts and rasterises it.
///
/// Parts live at `Resources/NotionAvatar/<part>/<index>.svg` (copied into the app bundle by
/// `make app`). Each file is already a 1080×1080 SVG; composition strips the outer `<svg>`
/// and nests groups — the same approach as Mayandev/notion-avatar’s preview pipeline.
@MainActor
enum NotionAvatarRenderer {
    private static let cache = NSCache<NSString, NSImage>()

    /// Rasterise `config` to an `NSImage` of the given side length (points).
    static func image(for config: NotionAvatarConfig, side: CGFloat) -> NSImage? {
        let key = cacheKey(config, side: side) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let svg = svgString(for: config),
              let image = rasterise(svg: svg, side: side) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func cacheKey(_ config: NotionAvatarConfig, side: CGFloat) -> String {
        [
            "\(config.face)", "\(config.eyes)", "\(config.eyebrows)", "\(config.glasses)",
            "\(config.hair)", "\(config.mouth)", "\(config.nose)", "\(config.accessories)",
            "\(config.beard)", "\(config.details)", "\(Int(side))",
        ].joined(separator: "-")
    }

    static func svgString(for config: NotionAvatarConfig) -> String? {
        var groups: [String] = []
        for part in NotionAvatarConfig.Part.drawOrder {
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
