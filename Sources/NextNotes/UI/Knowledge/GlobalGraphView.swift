import SwiftUI

/// The whole map: everything the assistant knows about, on one canvas you can move around.
///
/// It used to be a flat panel of identical dots inside a card, and clicking one threw the
/// pane onto a different screen. Three things changed. The canvas now runs edge to edge
/// under its own chrome, so it reads as a place rather than as a chart in a box. A dot's
/// size is how many things it is joined to, and the busiest ones carry their name and their
/// symbol, so the picture has a shape before you have touched it. And a click selects and
/// centres rather than navigating — the card that appears is where "open what's around it"
/// lives, taken on purpose instead of by accident.
///
/// The filter chips are also the legend: colour, name and count in one control, and
/// switching one off fades that family instead of deleting it, so you can still see the
/// shape it left behind.
struct GlobalGraphView: View {
    let expansion: KnowledgeGraphExpansion
    var eyebrow: String?
    var title: String
    var subtitle: String?
    /// Open the neighbourhood around a node — the deliberate move, not the click.
    var onOpen: (String) -> Void

    @State private var model = GraphLayoutModel()
    @State private var camera = GraphCamera()
    @State private var selection: String?
    @State private var muted: Set<GraphKind> = []

    var body: some View {
        GraphCanvas(
            nodes: expansion.nodes,
            edges: expansion.edges,
            model: model,
            selection: $selection,
            camera: $camera,
            mutedKinds: muted,
            wheelNavigates: true
        )
        // Both bands are one row rather than two opposite-corner overlays: in a narrow
        // detail pane the heading and the toolbar would otherwise sit on top of each other.
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                header
                Spacer(minLength: DS.Space.s)
                GraphToolbar(camera: $camera)
            }
            .padding(DS.Size.graphChromeInset)
        }
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                footer
                Spacer(minLength: DS.Space.s)
                card
            }
            .padding(DS.Size.graphChromeInset)
        }
        .overlay(alignment: .center) { settling }
        .frame(minHeight: DS.Size.graphMapMinHeight)
    }

    private var header: some View {
        SectionHeading(
            title: title,
            eyebrow: eyebrow,
            subtitle: subtitle,
            orb: .breathing,
            isOrbAnimated: false
        )
        .padding(DS.Space.cardTight)
        .frame(maxWidth: DS.Size.graphHeaderMaxWidth, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.graphChrome)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            GraphFilterChips(counts: counts, muted: $muted)
                .frame(maxWidth: DS.Size.graphChipsMaxWidth, alignment: .leading)
            GraphHint()
        }
    }

    @ViewBuilder
    private var card: some View {
        if let selection, let node = expansion.nodes.first(where: { $0.id == selection }) {
            GraphNodeCard(
                node: node,
                connections: model.layout.degree[selection] ?? 0,
                onOpen: { onOpen(selection) },
                onDismiss: { withAnimation(DS.Motion.graphHover) { self.selection = nil } }
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var settling: some View {
        if model.isSettling {
            Text("Laying out your map…")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .glassSurface(cornerRadius: DS.Radius.graphChrome)
        }
    }

    private var counts: [GraphKind: Int] {
        expansion.nodes.reduce(into: [:]) { totals, node in
            totals[GraphKind.of(node.type), default: 0] += 1
        }
    }
}
