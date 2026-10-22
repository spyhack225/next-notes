import AppKit
import Foundation

/// One complete Open Peeps sitting template per setup screen, used exactly as
/// drawn — each template's own integrated head, never covered, composited, or
/// replaced. The person's Notion avatar is never drawn onto a figure; it lives
/// where identity lives (the welcome face row, island, chat, About).
///
/// Art: Open Peeps sitting templates by Pablo Stanley (CC0) — see
/// `Resources/OpenPeeps/ATTRIBUTION.md`. Black strokes on transparent, sized by
/// the raster, so the fixed light theme needs no recoloring.
enum PeepScene: String, CaseIterable {
    case welcome
    case dictation
    case shortcut
    case meetings
    case files
    case brain
    case allSet

    /// Scene template per setup screen. The pose is the moment; every head is
    /// the template's own.
    var file: String {
        switch self {
        case .welcome: "welcome"
        case .dictation: "dictation"
        case .shortcut: "shortcut"
        case .meetings: "meetings"
        case .files: "files"
        case .brain: "brain"
        case .allSet: "allSet"
        }
    }
}

@MainActor
enum PeepFigure {
    private static let cache = NSCache<NSString, NSImage>()

    /// Renders `scene` at the requested height, preserving the template's own
    /// aspect: the single scene SVG, scaled, nothing added. Nil when the
    /// template cannot rasterise — callers show no figure rather than a
    /// half-built one.
    static func image(scene: PeepScene, height: CGFloat) -> NSImage? {
        let key = "\(scene.rawValue)-\(Int(height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = rasterScene(scene.file) else { return nil }
        let aspect = source.size.width / max(1, source.size.height)
        let size = NSSize(width: height * aspect, height: height)
        let composed = NSImage(size: size)
        composed.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero, operation: .sourceOver, fraction: 1)
        composed.unlockFocus()
        cache.setObject(composed, forKey: key)
        return composed
    }

    private static func rasterScene(_ name: String) -> NSImage? {
        guard let url = sceneURL(name),
              let source = NSImage(contentsOf: url),
              source.isValid
        else { return nil }
        return source
    }

    private static func sceneURL(_ name: String) -> URL? {
        let file = name + ".svg"
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("OpenPeeps", isDirectory: true)
            .appendingPathComponent("scenes", isDirectory: true)
            .appendingPathComponent(file),
            FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Bare `make build` binary: walk up from the executable toward the repo root.
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidate = url
                .appendingPathComponent("Resources/OpenPeeps", isDirectory: true)
                .appendingPathComponent("scenes", isDirectory: true)
                .appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
