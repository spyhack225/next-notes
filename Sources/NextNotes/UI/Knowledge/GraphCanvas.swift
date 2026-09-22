import AppKit
import SwiftUI

/// The map itself: one `Canvas`, one camera, and nothing around it.
///
/// Everything a person sees on the map is drawn here — the ground, the edges, the dots,
/// the glyphs inside the larger dots and the names beside them. The chrome that floats over
/// it (the toolbar, the chips, the legend, the card) is in `GraphChrome.swift`, and the
/// positions come from `GraphLayoutModel`, which the owning view holds so it can read the
/// same placements this one draws.
///
/// **Why one `Canvas` and not a view per node.** Several hundred nodes is several hundred
/// views, each with its own identity, animation and layout pass, for a picture that is
/// ninety-nine percent circles. The canvas draws the whole map in a couple of dozen fills:
/// edges are bucketed into three paths by weight and dots into one path per type and state,
/// so a redraw costs the number of *kinds* of thing on the map rather than the number of
/// things. Only the handful carrying a glyph or a name cost anything individually.
struct GraphCanvas: View {
    let nodes: [KnowledgeGraphNode]
    let edges: [KnowledgeGraphEdge]
    /// Held by the owner, because the toolbar and the detail card need the same placements
    /// and degrees this view draws from.
    let model: GraphLayoutModel
    /// The node wearing the ring and the glow. It keeps them after the pointer has left.
    @Binding var selection: String?
    @Binding var camera: GraphCamera
    /// Families whose chips are switched off. They stay on the map, nearly transparent —
    /// a map that silently drops half of itself is a different map and you cannot tell.
    var mutedKinds: Set<GraphKind> = []
    /// Name every node, not just the busy ones. Right for a neighbourhood of a dozen,
    /// wrong for a library of seven hundred.
    var namesEverything = false
    /// Whether the wheel pans and zooms here. Off inside a scrolling pane, where taking the
    /// wheel would trap the page.
    var wheelNavigates = false
    /// What a click does beyond selecting and centring. Nothing, on the whole map — the
    /// card that appears is where the next move lives.
    var onClick: (String) -> Void = { _ in }

    @State private var hoverID: String?
    @State private var pointer: CGPoint = .zero
    @State private var panOrigin: CGSize?
    @State private var pinchOrigin: CGFloat?
    @State private var wheel = GraphScrollMonitor()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                canvas(size: size)
                if let hoverID, hoverID != selection, let node = node(hoverID) {
                    hoverChip(node: node, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            .simultaneousGesture(pinchGesture(size: size))
            .simultaneousGesture(tapGesture(size: size))
            .onContinuousHover { phase in hovered(phase, size: size) }
            .task(id: InputKey(nodes: nodes.count, edges: edges.count,
                               first: nodes.first?.id, last: nodes.last?.id,
                               width: size.width, height: size.height)) {
                model.update(nodes: nodes, edges: edges, size: size)
            }
            .onDisappear { wheel.stop() }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Use the list beside the map to open any of these.")
    }

    /// Re-runs the layout when the graph or the frame really changed, and not on a hover.
    private struct InputKey: Equatable {
        var nodes: Int
        var edges: Int
        var first: String?
        var last: String?
        var width: CGFloat
        var height: CGFloat
    }

    // MARK: - Drawing

    private func canvas(size: CGSize) -> some View {
        Canvas(
            opaque: false,
            rendersAsynchronously: false,
            renderer: { context, canvasSize in
                draw(&context, size: canvasSize)
            },
            symbols: {
                // Resolved once and reused for every dot of that type, so a map with
                // eighty folders on it still costs one folder glyph.
                ForEach(Self.glyphTypes, id: \.self) { type in
                    Image(systemName: GraphNodeStyle.symbol(for: type))
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundStyle(DS.Color.content)
                        .tag(type)
                }
            }
        )
        .dottedField(opacity: DS.Opacity.graphFieldInk, fade: .radial)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let layout = model.layout
        guard !layout.placements.isEmpty else { return }

        let spotlight = hoverID ?? selection
        let lit = neighbourhood(of: spotlight)
        let margin = DS.Size.graphCullMargin
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -margin, dy: -margin)
        let dotZoom = pow(camera.zoom, DS.Size.graphZoomDotExponent)
        let busiest = layout.degree.values.max() ?? 1

        var screen = [String: CGPoint](minimumCapacity: layout.placements.count)
        for (id, point) in layout.placements { screen[id] = camera.project(point, in: size) }

        // MARK: Edges — three paths, whatever the edge count

        var quiet = Path()
        var resting = Path()
        var active = Path()
        for edge in edges {
            guard let a = screen[edge.from], let b = screen[edge.to] else { continue }
            guard visible.contains(a) || visible.contains(b) else { continue }
            let bowed = Self.bow(from: a, to: b)
            if spotlight != nil, edge.from == spotlight || edge.to == spotlight {
                active.addPath(bowed)
            } else if spotlight == nil {
                resting.addPath(bowed)
            } else {
                quiet.addPath(bowed)
            }
        }
        let thread = DS.Color.textTertiary
        context.stroke(quiet, with: .color(thread.opacity(DS.Opacity.graphEdgeDimmed)),
                       lineWidth: DS.Border.graphEdgeFaint)
        context.stroke(resting, with: .color(thread.opacity(DS.Opacity.graphEdgeResting)),
                       lineWidth: DS.Border.graphEdgeQuiet)
        context.stroke(active, with: .color(DS.Color.accent.opacity(DS.Opacity.graphEdgeActive)),
                       lineWidth: DS.Border.graphEdgeActive)

        // MARK: Dots — one path per type and state

        var discs = [Swatch: Path]()
        var glyphs: [(type: String, rect: CGRect)] = []
        var names: [(node: KnowledgeGraphNode, point: CGPoint, dot: CGFloat, strong: Bool)] = []
        glyphs.reserveCapacity(DS.Size.graphRestingLabels)
        names.reserveCapacity(DS.Size.graphRestingLabels)

        for node in nodes {
            guard let point = screen[node.id], visible.contains(point) else { continue }
            let emphasised = node.id == selection || node.id == hoverID
            let dot = Self.diameter(degree: layout.degree[node.id] ?? 0,
                                    busiest: busiest,
                                    zoom: dotZoom,
                                    emphasised: emphasised)
            let state: Swatch.State
            if mutedKinds.contains(GraphKind.of(node.type)) {
                state = .muted
            } else if spotlight == nil || lit.contains(node.id) {
                state = .lit
            } else {
                state = .aside
            }
            let rect = CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)
            discs[Swatch(type: node.type, state: state), default: Path()].addEllipse(in: rect)

            guard state == .lit else { continue }
            if dot >= DS.Size.graphGlyphThreshold, Self.glyphTypes.contains(node.type) {
                let side = dot * DS.Size.graphGlyphRatio
                glyphs.append((node.type, CGRect(x: point.x - side / 2, y: point.y - side / 2,
                                                 width: side, height: side)))
            }
            let prominent = model.prominent.contains(node.id)
            if namesEverything || emphasised || prominent || dot >= DS.Size.graphLabelThreshold {
                names.append((node, point, dot, emphasised || prominent))
            }
        }

        // Muted first, then set-aside, then lit, so the thing being looked at is on top.
        // Sorted rather than left to dictionary order, or the overlap would shuffle.
        for swatch in discs.keys.sorted() {
            guard let path = discs[swatch] else { continue }
            context.fill(path, with: .color(DS.Color.graphNode(swatch.type).opacity(swatch.state.alpha)))
        }

        for glyph in glyphs {
            guard let symbol = context.resolveSymbol(id: glyph.type) else { continue }
            context.opacity = DS.Opacity.graphNodeGlyph
            context.draw(symbol, in: glyph.rect)
            context.opacity = 1
        }

        // MARK: Selection and hover

        if let selection, let point = screen[selection], visible.contains(point) {
            let dot = Self.diameter(degree: layout.degree[selection] ?? 0, busiest: busiest,
                                    zoom: dotZoom, emphasised: true)
            let glow = dot + DS.Size.graphSelectionGlow
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - glow / 2, y: point.y - glow / 2,
                                       width: glow, height: glow)),
                with: .color(DS.Color.accent.opacity(DS.Opacity.graphSelectionGlow))
            )
            let ring = dot + DS.Size.graphNodeRingPad * 2
            context.stroke(
                Path(ellipseIn: CGRect(x: point.x - ring / 2, y: point.y - ring / 2,
                                       width: ring, height: ring)),
                with: .color(DS.Color.accent.opacity(DS.Opacity.graphFocusRing)),
                lineWidth: DS.Border.graphSelectionRing
            )
        }
        if let hoverID, hoverID != selection, let point = screen[hoverID], visible.contains(point) {
            let dot = Self.diameter(degree: layout.degree[hoverID] ?? 0, busiest: busiest,
                                    zoom: dotZoom, emphasised: true)
            let ring = dot + DS.Size.graphNodeRingPad * 2
            context.stroke(
                Path(ellipseIn: CGRect(x: point.x - ring / 2, y: point.y - ring / 2,
                                       width: ring, height: ring)),
                with: .color(DS.Color.text.opacity(DS.Opacity.graphHoverRing)),
                lineWidth: DS.Border.graphRing
            )
        }

        // MARK: Names

        for name in names {
            let text = Text(Self.shortened(name.node.label))
                .font(name.strong ? DS.Font.caption2.weight(.medium) : DS.Font.caption2)
                .foregroundStyle(name.strong ? DS.Color.text : DS.Color.textSecondary)
            let resolved = context.resolve(text)
            let room = CGSize(width: DS.Size.graphLabelMaxWidth, height: .greatestFiniteMagnitude)
            let measured = resolved.measure(in: room)
            let top = CGPoint(x: name.point.x, y: name.point.y + name.dot / 2 + DS.Space.xs)
            let plate = CGRect(x: top.x - measured.width / 2 - DS.Space.xs,
                               y: top.y - DS.Space.xxs,
                               width: measured.width + DS.Space.s,
                               height: measured.height + DS.Space.xs)
            context.fill(
                Path(roundedRect: plate, cornerRadius: DS.Radius.graphHoverChip, style: .continuous),
                with: .color(DS.Color.content.opacity(DS.Opacity.graphLabelPlate))
            )
            context.draw(resolved, at: top, anchor: .top)
        }
    }

    /// Ink and state for one bucket of dots. `Comparable` so the draw order is fixed and
    /// two overlapping dots never swap which one is in front between frames.
    private struct Swatch: Hashable, Comparable {
        enum State: Int, Comparable {
            case muted = 0, aside = 1, lit = 2

            var alpha: Double {
                switch self {
                case .muted: DS.Opacity.graphFilteredOut
                case .aside: DS.Opacity.graphDimmed
                case .lit: 1
                }
            }

            static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
        }

        let type: String
        let state: State

        static func < (a: Swatch, b: Swatch) -> Bool {
            a.state != b.state ? a.state < b.state : a.type < b.type
        }
    }

    /// A gentle, always-the-same bow away from the straight line. Consistently handed, so
    /// the whole map curves one way and reads as a field rather than as a wiring diagram.
    private static func bow(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        let run = b.x - a.x
        let rise = b.y - a.y
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let lift = DS.Size.graphEdgeBow
        path.addQuadCurve(to: b, control: CGPoint(x: middle.x - rise * lift,
                                                  y: middle.y + run * lift))
        return path
    }

    /// Size means degree: how many things this one is joined to. Logarithmic, because one
    /// person in fifty meetings should not be eight times the dot of one in six.
    private static func diameter(degree: Int, busiest: Int, zoom: CGFloat, emphasised: Bool) -> CGFloat {
        let ceiling = log(Double(max(busiest, 1)) + 1)
        let share = ceiling > 0 ? min(1, log(Double(degree) + 1) / ceiling) : 0
        let span = DS.Size.graphDotMax - DS.Size.graphDotMin
        var dot = (DS.Size.graphDotMin + span * CGFloat(share)) * zoom
        if emphasised { dot = max(dot, DS.Size.graphGlyphThreshold) }
        return dot
    }

    /// A name long enough to wrap into a paragraph is not a label. Cut rather than let a
    /// file called "Q3 pricing — final (revised) v7" become four lines on the map.
    private static func shortened(_ label: String) -> String {
        let limit = DS.Size.graphLabelCharacters
        guard label.count > limit else { return label }
        return label.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Every ontology type that has a glyph worth drawing inside a dot.
    private static let glyphTypes = [
        "Person", "Meeting", "Decision", "ActionItem", "OpenQuestion", "Artifact",
        "Topic", "Project", "Organization", "Place", "Activity", "Goal",
        "Preference", "Event", "Folder", "File",
    ]

    // MARK: - Hover chip

    private func hoverChip(node: KnowledgeGraphNode, size: CGSize) -> some View {
        let point = model.layout.placements[node.id].map { camera.project($0, in: size) } ?? .zero
        let edge = DS.Size.graphCanvasInset
        return HStack(spacing: DS.Space.xs) {
            Image(systemName: GraphNodeStyle.symbol(for: node.type))
                .font(DS.Font.caption2)
                .foregroundStyle(DS.Color.graphNode(node.type))
            VStack(alignment: .leading, spacing: 0) {
                Text(node.label)
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundStyle(DS.Color.text)
                    .lineLimit(2)
                Text(GraphNodeStyle.singular(for: node.type))
                    .font(DS.Font.caption2)
                    .foregroundStyle(DS.Color.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .frame(maxWidth: DS.Size.graphHoverLabelMaxWidth, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.graphHoverChip)
        .position(x: min(max(point.x, edge), max(size.width - edge, edge)),
                  y: max(edge, point.y - DS.Size.graphDotMax))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Interaction

    private var hoverMotion: Animation? { reduceMotion ? nil : DS.Motion.graphHover }
    private var focusMotion: Animation? { reduceMotion ? nil : DS.Motion.graphFocus }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: DS.Size.graphPanThreshold)
            .onChanged { value in
                if panOrigin == nil { panOrigin = camera.pan }
                let base = panOrigin ?? .zero
                camera.pan = CGSize(width: base.width + value.translation.width,
                                    height: base.height + value.translation.height)
            }
            .onEnded { _ in panOrigin = nil }
    }

    private func pinchGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchOrigin == nil { pinchOrigin = camera.zoom }
                let base = pinchOrigin ?? 1
                camera.setZoom(base * value.magnification, around: value.startLocation, in: size)
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    private func tapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let hit = nearest(value.location, size: size) else {
                    withAnimation(focusMotion) { selection = nil }
                    return
                }
                withAnimation(focusMotion) {
                    selection = hit
                    if let point = model.layout.placements[hit] {
                        camera.centre(on: point, in: size)
                    }
                }
                onClick(hit)
            }
    }

    private func hovered(_ phase: HoverPhase, size: CGSize) {
        switch phase {
        case .active(let point):
            pointer = point
            let hit = nearest(point, size: size)
            if hit != hoverID { withAnimation(hoverMotion) { hoverID = hit } }
            if wheelNavigates, !wheel.isRunning {
                wheel.handler = { delta, zooming in navigate(by: delta, zooming: zooming, in: size) }
                wheel.start()
            }
        case .ended:
            withAnimation(hoverMotion) { hoverID = nil }
            wheel.stop()
        }
    }

    /// The wheel pans, and pans *with* the content the way a trackpad does. Holding Command
    /// or Option turns the same gesture into a zoom about the pointer, which is the one
    /// thing a wheel cannot say on its own.
    private func navigate(by delta: CGSize, zooming: Bool, in size: CGSize) {
        if zooming {
            let factor = pow(2, delta.height / DS.Size.graphScrollZoomRate)
            camera.setZoom(camera.zoom * factor, around: pointer, in: size)
        } else {
            camera.pan = CGSize(width: camera.pan.width + delta.width,
                                height: camera.pan.height + delta.height)
        }
    }

    /// The nearest node within a hit radius. Larger than the drawn dot on purpose: a seven
    /// point circle is not a click target.
    private func nearest(_ point: CGPoint, size: CGSize) -> String? {
        let layout = model.layout
        guard !layout.placements.isEmpty else { return nil }
        let reach = DS.Size.graphNodeHitRadius
        var best: (id: String, distance: CGFloat)?
        for (id, placed) in layout.placements {
            let screen = camera.project(placed, in: size)
            let distance = hypot(screen.x - point.x, screen.y - point.y)
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        return best?.id
    }

    private func node(_ id: String) -> KnowledgeGraphNode? {
        nodes.first { $0.id == id }
    }

    private func neighbourhood(of id: String?) -> Set<String> {
        guard let id else { return [] }
        var ids: Set<String> = [id]
        for edge in edges {
            if edge.from == id { ids.insert(edge.to) }
            if edge.to == id { ids.insert(edge.from) }
        }
        return ids
    }

    // MARK: - VoiceOver

    private var accessibilityLabel: String {
        guard let selection, let node = node(selection) else { return "Your map" }
        return "Your map, centred on \(node.label)"
    }

    private var accessibilityValue: String {
        let families = Dictionary(grouping: nodes) { GraphKind.of($0.type) }
        let parts = GraphKind.allCases.compactMap { kind -> String? in
            guard let found = families[kind], !found.isEmpty else { return nil }
            return "\(found.count) \(kind.title.lowercased())"
        }
        guard !parts.isEmpty else { return "Nothing on it yet." }
        return parts.joined(separator: ", ") + "."
    }
}
