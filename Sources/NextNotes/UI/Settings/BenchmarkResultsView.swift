import SwiftUI
import WebKit

/// User-opened access to the same published catalog. No benchmark or repository scan
/// runs in the application, and the web process exists only while this sheet is open.
struct BenchmarkResultsView: View {
    static let publishedURL = URL(string: "https://next-notes.com/?page=benchmarks")!
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            HStack {
                Text("Benchmark results").font(DS.Font.body)
                Spacer()
                Link("Open in browser", destination: Self.publishedURL)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DS.Space.l)
            Divider()
            if failed {
                ContentUnavailableView {
                    Label("Results could not load", systemImage: "wifi.slash")
                } description: {
                    Text("Check your connection, then try opening the results again.")
                } actions: {
                    Link("Open in browser", destination: Self.publishedURL)
                }
            } else {
                PublishedBenchmarkPage(failed: $failed, loading: $loading)
                    .overlay {
                        if loading { ProgressView("Loading results…") }
                    }
            }
        }
        .frame(width: DS.Size.sheetEditorWidth, height: DS.Size.sheetEditorHeight)
    }
}

private struct PublishedBenchmarkPage: NSViewRepresentable {
    @Binding var failed: Bool
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed, loading: $loading) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: BenchmarkResultsView.publishedURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var failed: Bool
        @Binding var loading: Bool
        init(failed: Binding<Bool>, loading: Binding<Bool>) {
            _failed = failed
            _loading = loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed = true
        }
    }
}
