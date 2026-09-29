import AppKit
import SwiftUI
import WebKit

/// A local rich-text page. The bundled editor never loads a remote script or sends a note
/// over the network. HTML preserves the editing surface; Markdown continues to feed the
/// meeting's existing scratchpad merge and summary path.
struct MeetingRichEditor: NSViewRepresentable {
    let html: String?
    let markdown: String
    let onChange: (String, String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "notes")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        if let directory = Self.resourceDirectory {
            view.loadFileURL(directory.appendingPathComponent("index.html"),
                             allowingReadAccessTo: directory)
        } else {
            onError("The notes editor could not be loaded. Please rebuild the app.")
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfReady()
    }

    static var resourceDirectory: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("MeetingEditor")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("editor.js").path) {
            return bundled
        }
        // Bare development binaries have no app bundle. The checked-in assets still let
        // the panel run while iterating locally.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = source.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let local = repository.appendingPathComponent("Resources/MeetingEditor")
        return FileManager.default.fileExists(atPath: local.appendingPathComponent("editor.js").path)
            ? local : nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: MeetingRichEditor
        weak var webView: WKWebView?
        var ready = false
        var loaded = false

        init(_ parent: MeetingRichEditor) { self.parent = parent }

        func loadIfReady() {
            guard ready, !loaded, let webView else { return }
            let payload: [String: String] = ["html": parent.html ?? "", "markdown": parent.markdown]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            loaded = true
            webView.evaluateJavaScript("window.setDocument(\(json))") { [weak self] _, error in
                if error != nil { self?.parent.onError("The notes editor could not open this page.") }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
            switch type {
            case "ready": ready = true; loadIfReady()
            case "changed":
                guard let html = payload["html"] as? String,
                      let markdown = payload["markdown"] as? String else { return }
                parent.onChange(html, markdown)
            case "error": if let text = payload["message"] as? String { parent.onError(text) }
            case "copy":
                if let text = payload["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "openLink":
                if let text = payload["url"] as? String, let url = URL(string: text),
                   ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.isFileURL == true
                            ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onError("The notes editor could not open this page.")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.onError("The notes editor could not open this page.")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("typeof window.setDocument === 'function'") { [weak self] value, _ in
                if value as? Bool != true {
                    self?.parent.onError("The notes editor could not start. Please rebuild the app.")
                }
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "Add link")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 310, height: 24)
            alert.accessoryView = field
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
}
