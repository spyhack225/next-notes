import AppKit
import Foundation

/// An off-screen window the computer self-test owns, so click/type do not hit Cursor.
@MainActor
final class ComputerSelfTestHarness: NSObject {
    private let window: NSWindow
    private let field: NSTextField
    private(set) var buttonClicked = false

    override init() {
        let field = NSTextField(string: "")
        field.placeholderString = "Type here"
        field.isEditable = true
        field.isSelectable = true
        field.identifier = NSUserInterfaceItemIdentifier("nextnotes-selftest-field")
        self.field = field

        let button = NSButton(title: "OK", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("nextnotes-selftest-ok")

        let stack = NSStackView(views: [field, button])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 280, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Next Notes Computer Self-Test"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.level = .floating
        self.window = window
        super.init()
        button.target = self
        button.action = #selector(clicked)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(field)
    }

    func close() {
        window.orderOut(nil)
    }

    var fieldValue: String { field.stringValue }

    @objc private func clicked() {
        buttonClicked = true
    }
}