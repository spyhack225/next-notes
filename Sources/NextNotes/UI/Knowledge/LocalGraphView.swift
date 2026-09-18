import SwiftUI

/// One focus node and its immediate neighbours (Part 4, Phase F).
///
/// Node count on screen is bounded by one node's degree, so the picture reads the same at
/// 12 meetings and at 180. Hover isolates the neighbourhood; everything else fades. Click
/// a neighbour to re-centre — that is how you walk the graph, one hop at a time.
struct LocalGraphView: View {
    let expansion: KnowledgeGraphExpansion
    let focusID: String
    var onFocus: (String) -> Void

    @State private var hoverID: String?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let layout = ForceLayout(
                ids: expansion.nodes.map(\.id),
                edges: expansion.edges.map { ($0.from, $0.to) },
                size: size
            )
            ZStack {
                Canvas { context, _ in
                    draw(context: &context, layout: layout, size: size)
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let hit = nearest(value.location, in: layout) {
                        onFocus(hit)
                    }
                })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverID = nearest(point, in: layout)
                    case .ended:
                        hoverID = nil
                    }
                }

                ForEach(expansion.nodes, id: \.id) { node in
                    if let point = layout.placements[node.id] {
                        Text(node.label)
                            .font(DS.Font.caption)
                            .foregroundStyle(labelInk(for: node.id))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: DS.Size.graphLabelMaxWidth)
                            .position(x: point.x, y: point.y + DS.Size.graphNodeDot + DS.Space.xs)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onAppear { canvasSize = size }
            .onChange(of: size) { _, next in canvasSize = next }
        }
        .frame(minHeight: DS.Size.graphCanvasMinHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local graph centred on \(focusLabel)")
    }

    private var focusLabel: String {
        expansion.nodes.first { $0.id == focusID }?.label ?? focusID
    }

    private var neighbourIDs: Set<String> {
        guard let hover = hoverID else { return Set(expansion.nodes.map(\.id)) }
        var ids: Set<String> = [hover]
        for edge in expansion.edges {
            if edge.from == hover { ids.insert(edge.to) }
            if edge.to == hover { ids.insert(edge.from) }
        }
        return ids
    }

    private func labelInk(for id: String) -> Color {
        let active = hoverID == nil || neighbourIDs.contains(id)
        return DS.Color.text.opacity(active ? 1 : DS.Opacity.graphDimmed)
    }

    private func draw(context: inout GraphicsContext, layout: ForceLayout, size: CGSize) {
        let neighbours = neighbourIDs
        let hovering = hoverID != nil
        for edge in expansion.edges {
            guard let a = layout.placements[edge.from], let b = layout.placements[edge.to] else { continue }
            let touchesHover = !hovering || edge.from == hoverID || edge.to == hoverID
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            context.stroke(
                path,
                with: .color(DS.Color.textTertiary.opacity(touchesHover ? DS.Opacity.secondaryFill : DS.Opacity.graphEdgeDimmed)),
                lineWidth: DS.Border.hairline
            )
        }
        for node in expansion.nodes {
            guard let point = layout.placements[node.id] else { continue }
            let active = !hovering || neighbours.contains(node.id)
            let isFocus = node.id == focusID
            let radius = isFocus ? DS.Size.graphNodeDot * 1.35 : DS.Size.graphNodeDot
            let rect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(ink(for: node).opacity(active ? 1 : DS.Opacity.graphDimmed))
            )
        }
        _ = size
    }

    private func ink(for node: KnowledgeGraphNode) -> Color {
        if node.id == focusID { return DS.Color.accent }
        switch node.type {
        case "Person": return DS.Color.text
        case "Meeting": return DS.Color.textSecondary
        case "Decision", "ActionItem": return DS.Color.success
        default: return DS.Color.textTertiary
        }
    }

    private func nearest(_ point: CGPoint, in layout: ForceLayout) -> String? {
        let hitRadius = DS.Size.graphNodeHitRadius
        var best: (String, CGFloat)?
        for (id, placed) in layout.placements {
            let distance = hypot(placed.x - point.x, placed.y - point.y)
            guard distance <= hitRadius else { continue }
            if best == nil || distance < best!.1 { best = (id, distance) }
        }
        return best?.0
    }
}
