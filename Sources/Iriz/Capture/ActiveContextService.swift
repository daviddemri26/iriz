@preconcurrency import AppKit
import ApplicationServices
import Foundation

struct ActiveContext: Equatable, Sendable {
    var applicationName: String?
    var bundleIdentifier: String?
    var windowTitle: String?
    var url: URL?
    var isMeeting: Bool
}

actor ActiveContextService {
    func current(settings: IrizSettings) -> ActiveContext? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleIdentifier = application.bundleIdentifier
        let applicationName = application.localizedName
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: appElement),
           copyStringAttribute(kAXSubroleAttribute as CFString, from: focused) == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        let window = copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
        let title = window.flatMap { copyStringAttribute(kAXTitleAttribute as CFString, from: $0) }
        let url = window.flatMap(findURL(in:))
        let context = ActiveContext(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: title,
            url: url,
            isMeeting: MeetingDetector.isMeeting(bundleIdentifier: bundleIdentifier, title: title, url: url)
        )
        guard !ExclusionPolicy.shouldExclude(
            bundleIdentifier: context.bundleIdentifier,
            windowTitle: context.windowTitle,
            url: context.url,
            settings: settings
        ) else { return nil }
        return context
    }

    private func findURL(in root: AXUIElement) -> URL? {
        if let value = copyAttribute("AXURL" as CFString, from: root) {
            if CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? URL { return url }
            if let string = value as? String, let url = normalizedURL(string) { return url }
        }

        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 250 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            let description = [
                copyStringAttribute(kAXDescriptionAttribute as CFString, from: element),
                copyStringAttribute(kAXTitleAttribute as CFString, from: element)
            ].compactMap { $0 }.joined(separator: " ").lowercased()
            if role == (kAXTextFieldRole as String),
               ["address", "search", "url", "adresse"].contains(where: description.contains),
               let value = copyStringAttribute(kAXValueAttribute as CFString, from: element),
               let url = normalizedURL(value) {
                return url
            }
            guard depth < 7,
                  let children = copyAttribute(kAXChildrenAttribute as CFString, from: element) as? [AXUIElement] else {
                continue
            }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

    private func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.contains("."), !trimmed.contains(" ") { return URL(string: "https://\(trimmed)") }
        return nil
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }
}

enum MeetingDetector {
    private static let appIdentifiers = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2"]

    static func isMeeting(bundleIdentifier: String?, title: String?, url: URL?) -> Bool {
        if let bundleIdentifier, appIdentifiers.contains(where: bundleIdentifier.lowercased().contains) { return true }
        let value = [title, url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        return value.contains("meet.google.com") || value.contains("zoom meeting") || value.contains("microsoft teams meeting")
    }
}
