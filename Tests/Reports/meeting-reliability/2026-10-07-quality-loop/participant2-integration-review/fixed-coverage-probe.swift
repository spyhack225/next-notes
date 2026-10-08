import Foundation
@MainActor final class Node {
    let role: String
    let title: String
    let children: [Node]
    init(_ title: String = "", role: String = "AXGroup", children: [Node] = []) {
        self.title = title; self.role = role; self.children = children
    }
}
typealias AXUIElement = Node
typealias CFTypeRef = Any
typealias CFString = String
let kAXRoleAttribute = "role", kAXTitleAttribute = "title"
let kAXValueAttribute = "value", kAXChildrenAttribute = "children"
enum ReadStatus { case success }
@MainActor @discardableResult func AXUIElementCopyAttributeValue(
    _ node: Node, _ attribute: String, _ value: inout Any?) -> ReadStatus {
    switch attribute {
    case "role": value = node.role
    case "title": value = node.title
    case "children": value = node.children
    default: value = nil
    }
    return .success
}

@MainActor enum Snapshot {
    struct CaptureCoverage: Codable, Sendable, Equatable {
        let depthLimit: Int
        let childrenLimit: Int
        let usefulControlLimit: Int
        var depthLimitReached = false
        var childrenLimitReached = false
        var usefulControlLimitReached = false

        var limitReached: Bool {
            depthLimitReached || childrenLimitReached || usefulControlLimitReached
        }
    }
    private static var last: [String: AXUIElement] = [:]
    static func captureFixture(_ node: Node) -> ([String], CaptureCoverage?) {
        last = [:]; var lines: [String] = []
        var coverage = CaptureCoverage(depthLimit: 8, childrenLimit: 40, usefulControlLimit: 120)
        walk(node, depth: 0, remaining: 120, prefix: "generic.", into: &lines, coverage: &coverage)
        return (lines, coverage)
    }
    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        remaining: Int,
        prefix: String,
        into lines: inout [String],
        coverage: inout CaptureCoverage
    ) {
        guard remaining > last.count else {
            coverage.usefulControlLimitReached = true
            return
        }
        guard depth < coverage.depthLimit else {
            coverage.depthLimitReached = true
            return
        }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "Unknown"
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let title = titleRef as? String
        let value = valueRef as? String
        if isUseful(role: role, title: title, value: value) {
            let id = "\(prefix)\(last.count + 1)"
            last[id] = element
            var line = "\(shortRole(role)) id: \(id)"
            if let title, !title.isEmpty { line += "  label: \(title)" }
            if let value, !value.isEmpty, value.count < 80 { line += "  value: \(value)" }
            lines.append(line)
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return }
        if children.count > coverage.childrenLimit { coverage.childrenLimitReached = true }
        for child in children.prefix(coverage.childrenLimit) {
            walk(child, depth: depth + 1, remaining: remaining, prefix: prefix, into: &lines, coverage: &coverage)
            if last.count >= remaining {
                // Reaching the budget does not prove omitted nodes exist, but it
                // also cannot certify that the traversal reached every control.
                coverage.usefulControlLimitReached = true
                return
            }
        }
    }
    private static func isUseful(role: String, title: String?, value: String?) -> Bool {
        switch role {
        case "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
             "AXTab", "AXLink", "AXPopUpButton", "AXComboBox", "AXMenuItem", "AXStaticText":
            return !(title ?? "").isEmpty || !(value ?? "").isEmpty || role != "AXStaticText"
        default:
            return false
        }
    }
    private static func shortRole(_ role: String) -> String {
        String(role.dropFirst(2))
    }
}
struct BrowserCDPTarget { var id: String; var url: String; var webSocketDebuggerURL: String }
enum Probe {
    enum Selection: Equatable {
        case selected(Int)
        case unavailable
        case ambiguous
    }
    static func meetSelection(_ targets: [BrowserCDPTarget]) -> Selection {
        let indices = targets.indices.filter {
            guard let url = URL(string: targets[$0].url) else { return false }
            return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "meet.google.com"
                && !url.path.isEmpty && url.path != "/"
        }
        guard let index = indices.first else { return .unavailable }
        guard indices.count == 1 else { return .ambiguous }
        let target = targets[index]
        guard !target.id.isEmpty, let socket = URL(string: target.webSocketDebuggerURL),
              ["ws", "wss"].contains(socket.scheme?.lowercased() ?? ""), socket.host != nil else {
            return .unavailable
        }
        return .selected(index)
    }
}
@main struct Run {
    @MainActor static func main() {
        var checks = 0, failures = 0
        func expect(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + name) }
        }
        let wide = Node(children: (0..<41).map { Node("child-\($0)", role: "AXStaticText") })
        let w = Snapshot.captureFixture(wide)
        expect(w.0.count == 40, "same actual child cap output")
        expect(w.1?.childrenLimitReached == true, "child omission reported")
        var deep = Node("excluded", role: "AXStaticText")
        for _ in 0..<8 { deep = Node(children: [deep]) }
        let d = Snapshot.captureFixture(deep)
        expect(d.0.isEmpty, "same actual depth cap output")
        expect(d.1?.depthLimitReached == true, "depth omission reported")
        let useful = Node(children: (0..<4).map { group in
            Node(children: (0..<39).map { Node("leaf-\(group)-\($0)", role: "AXStaticText") })
        })
        let u = Snapshot.captureFixture(useful)
        expect(u.0.count == 120, "same actual useful-control cap output")
        expect(u.1?.usefulControlLimitReached == true, "useful budget reached reported")
        let small = Snapshot.captureFixture(Node("small", role: "AXStaticText"))
        expect(small.0.count == 1, "same small output")
        expect(small.1?.limitReached == false, "small limits not observed")
        let target = BrowserCDPTarget(id: "generic", url: "https://meet.google.com/abc-defg-hij",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/generic")
        var landing = target; landing.url = "https://meet.google.com"
        var root = target; root.url = "https://meet.google.com/"
        expect(Probe.meetSelection([landing]) == .unavailable, "landing refused")
        expect(Probe.meetSelection([root]) == .unavailable, "root landing refused")
        expect(Probe.meetSelection([target]) == .selected(0), "room raw observation remains possible")
        print("PARTICIPANT_COVERAGE_" + (failures == 0 ? "OK" : "FAILED")
            + " checks=\(checks) failures=\(failures) substituted-AX-boundary")
        if failures != 0 { exit(1) }
    }
}
