import AppKit
import Foundation

// Renders AppIcon.icns from code — no design tool, no binary asset to drift from the app.
//
// This file is compiled *together with* `OrbGeometry.swift` (see the `icon` target in the
// Makefile) rather than carrying its own copy of the maths. The mark is not a drawing of
// the orb, it is the orb: the same generator, the same tuned constants, the same frame the
// app shows when motion is turned off. Change the animation and the icon follows.

// MARK: - Identity

/// The mark is `listening` — a waveform rolling through latitude rings.
///
/// Of the nine states it is the one that is about *speech*, which is the whole app, and it
/// is the only one that is symmetric enough to survive being shrunk to 16pt.
let markState = OrbGeometry.State.listening

/// The pose, in seconds into the animation.
///
/// The same instant `ThinkingOrb` freezes on for `prefers-reduced-motion`, chosen there
/// because it reads as a diagram rather than as a thing caught mid-motion. That is exactly
/// what a logo needs, so the two agree by construction rather than by coincidence.
let markTime: Double = 1.7

/// Ground and ink.
///
/// Monochrome on purpose. The orb is drawn in a single ink with no gradient, no glow and no
/// second colour, and an icon that broke that rule would be advertising a design the app
/// does not have. Red is not used at all: in this app red means recording, and an icon is
/// not a recording. The ground is a warm near-black rather than a pure one so it does not
/// read as a hole in a dark Dock.
let ground = NSColor(srgbRed: 0.106, green: 0.102, blue: 0.114, alpha: 1)
let groundEdge = NSColor(srgbRed: 0.216, green: 0.212, blue: 0.231, alpha: 1)
let ink = NSColor(srgbRed: 0.949, green: 0.937, blue: 0.910, alpha: 1)

// MARK: - Drawing

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS Big Sur+ icon grid: the art occupies the middle ~82%, leaving the gutter the
    // system expects for its own shadow.
    let inset = size * 0.09
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // Apple's squircle corner is ~22.37% of the tile's edge.
    let radius = rect.width * 0.2237
    let squircle = CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.035,
        color: NSColor.black.withAlphaComponent(0.30).cgColor
    )
    ctx.addPath(squircle)
    ctx.setFillColor(ground.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // A hairline lip, so the tile still has an edge against a black wallpaper. Below about
    // 32px it is thinner than a pixel and would only turn the border to mud, so it stops.
    if size >= 32 {
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setStrokeColor(groundEdge.cgColor)
        ctx.setLineWidth(max(1, size * 0.004))
        ctx.strokePath()
        ctx.restoreGState()
    }

    drawOrb(in: ctx, tile: rect, size: size)
    return image
}

/// Draws the orb centred in the tile.
///
/// The geometry is generated at its own 64pt design size and then scaled, rather than
/// generated at the icon's size: the presets are two hand-tuned designs, not a scale factor,
/// so asking for a 512pt orb would not give a bigger version of the same drawing. Scaling
/// the 64pt one keeps the proportions the animation actually has.
func drawOrb(in ctx: CGContext, tile: CGRect, size: CGFloat) {
    // Which of the two tuned designs to draw, by how many pixels there are to draw it in.
    //
    // This is the whole reason the library ships two presets rather than one and a scale
    // factor: the large design's 134 dots are correct at 64pt and become a grey smudge at
    // 32px, where the inline design's handful of fatter dots still reads as a sphere. The
    // threshold is where measuring says the change happens, not a round number.
    let inline = size < 96
    let design: CGFloat = inline ? 20 : 64

    // How much of the tile the mark fills. The small design is given more room because it
    // has fewer marks to carry the shape, and at that size the squircle's curve is far
    // enough away in absolute pixels to allow it.
    let diameter = tile.width * (inline ? 0.74 : 0.62)
    let scale = diameter / design

    let frame = OrbGeometry.fullFrame(
        for: markState,
        size: design,
        time: markTime,
        inline: inline
    )

    ctx.saveGState()
    ctx.translateBy(x: tile.midX - diameter / 2, y: tile.midY - diameter / 2)
    ctx.scaleBy(x: scale, y: scale)

    // Edges under nodes, matching how `ThinkingOrb` paints. `listening` has none, but the
    // icon is generated from whichever state is set above and should not quietly lose half
    // the drawing if that is ever changed to `connecting` or `weaving`.
    for segment in frame.segments {
        ctx.setStrokeColor(ink.withAlphaComponent(segment.opacity).cgColor)
        ctx.setLineWidth(segment.width)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: segment.x1, y: segment.y1))
        ctx.addLine(to: CGPoint(x: segment.x2, y: segment.y2))
        ctx.strokePath()
    }

    // A dot smaller than about two thirds of a pixel antialiases into nothing, so the far
    // side of the sphere quietly vanishes and the mark stops reading as round. Floored in
    // device pixels and converted back through the scale, so it is a no-op at large sizes.
    let minimumRadius = (0.34 / scale)

    for dot in frame.dots {
        let radius = max(dot.radius, minimumRadius)
        ctx.setFillColor(ink.withAlphaComponent(dot.opacity).cgColor)
        ctx.fillEllipse(in: CGRect(
            x: dot.x - radius,
            y: dot.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    ctx.restoreGState()
}

// MARK: - Export

func png(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Redrawn at native pixel size rather than scaling one render — the dots are small, and
    // resampling them turns the 16pt icon to mud.
    drawIcon(size: CGFloat(pixels)).draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

/// An explicit entry point rather than top-level code: this is compiled *with*
/// `OrbGeometry.swift`, and Swift only allows statements at file scope in `main.swift`.
@main
enum MakeIcon {
    /// (point size, scale) pairs iconutil expects.
    static let variants: [(Int, Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
        (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

        for (points, scale) in variants {
            let pixels = points * scale
            guard let data = png(pixels: pixels) else {
                print("failed at \(pixels)px")
                exit(1)
            }
            let suffix = scale == 2 ? "@2x" : ""
            try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        }

        print("wrote \(variants.count) PNGs to Resources/AppIcon.iconset — \(markState.rawValue) orb")
    }
}
