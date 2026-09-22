import SwiftUI

/// One node and everything a single step away from it.
///
/// Node count on screen is bounded by one node's degree, so the picture reads the same at
/// twelve meetings and at a hundred and eighty — which is why this one names every node
/// rather than only the busy ones, and why the dots are drawn from the same canvas the
/// whole map uses. Clicking a neighbour re-centres on it: that is how you walk the graph,
/// one hop at a time.
///
/// It lives inside a scrolling pane, so it deliberately does **not** take the scroll wheel.
/// Pinch, drag and the zoom buttons move it; the wheel still scrolls the page, which is
/// what anybody reading the timeline under it expects.
struct LocalGraphView: View {
    let expansion: KnowledgeGraphExpansion
    let focusID: String
    var onFocus: (String) -> Void

    @State private var model = GraphLayoutModel()
    @State private var camera = GraphCamera()
    @State private var selection: String?

    var body: some View {
        GraphCanvas(
            nodes: expansion.nodes,
            edges: expansion.edges,
            model: model,
            selection: $selection,
            camera: $camera,
            namesEverything: true,
            onClick: { id in if id != focusID { onFocus(id) } }
        )
        .overlay(alignment: .topTrailing) {
            GraphToolbar(camera: $camera)
                .padding(DS.Size.graphChromeInset)
        }
        .frame(minHeight: DS.Size.graphCanvasMinHeight)
        .onAppear { selection = focusID }
        .onChange(of: focusID) { _, next in
            // A new centre is a new picture: the old camera would leave it off-screen.
            selection = next
            camera = GraphCamera()
        }
    }
}
