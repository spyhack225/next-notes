import AppKit
import Foundation

/// What a standing "yes" is allowed to cover. A grant for `computer.click` in Chrome
/// must not also click in Mail.
enum PermissionScopeKind: String, Codable, Sendable, CaseIterable {
    case any
    case application
    case domain
    case path
    case project
}

struct PermissionScope: Codable, Equatable, Sendable {
    var kind: PermissionScopeKind
    var value: String

    static let any = PermissionScope(kind: .any, value: "")

    var displayName: String {
        switch kind {
        case .any:
            return "Anywhere"
        case .application:
            return value
        case .domain:
            return value
        case .path:
            return value
        case .project:
            return value
        }
    }

    var alwaysLabel: String {
        switch kind {
        case .any:
            return "Always allow this action"
        case .application:
            return "Always allow for \(value)"
        case .domain:
            return "Always allow on \(value)"
        case .path:
            return "Always allow in this folder"
        case .project:
            return "Always allow in \(value)"
        }
    }

    /// A stored grant covers a request when it is unrestricted, or when it names the
    /// same (or a parent) place.
    func covers(_ request: PermissionScope) -> Bool {
        switch kind {
        case .any:
            return true
        case .application:
            return request.kind == .application
                && value.caseInsensitiveCompare(request.value) == .orderedSame
        case .domain:
            guard request.kind == .domain else { return false }
            let haystack = request.value.lowercased()
            let needle = value.lowercased()
            return haystack == needle || haystack.hasSuffix("." + needle)
        case .path:
            guard request.kind == .path else { return false }
            let prefix = value.hasSuffix("/") ? value : value + "/"
            return request.value == value || request.value.hasPrefix(prefix)
        case .project:
            return request.kind == .project
                && value.caseInsensitiveCompare(request.value) == .orderedSame
        }
    }
}

/// Pulls a scope out of the tool arguments, then the frontmost app for computer/browser.
enum PermissionScopeResolver {
    @MainActor
    static func inferred(tool: AgentTool, arguments: [String: String]) -> PermissionScope {
        if let path = first(arguments, keys: ["path", "folder", "file", "directory"]) {
            return PermissionScope(kind: .path, value: path)
        }
        if let url = arguments["url"], let host = host(of: url) {
            return PermissionScope(kind: .domain, value: host)
        }
        if let app = first(arguments, keys: ["app", "bundle", "bundleID", "application"]) {
            return PermissionScope(kind: .application, value: app)
        }
        if let project = arguments["project"], !project.isEmpty {
            return PermissionScope(kind: .project, value: project)
        }
        if tool.namespace == .computer || tool.namespace == .browser,
           let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            return PermissionScope(kind: .application, value: bundle)
        }
        return .any
    }

    private static func first(_ arguments: [String: String], keys: [String]) -> String? {
        for key in keys {
            let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func host(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty {
            return host
        }
        return nil
    }
}
