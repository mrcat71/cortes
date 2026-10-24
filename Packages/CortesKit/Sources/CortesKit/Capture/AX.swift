import ApplicationServices
import CoreGraphics
import Foundation

/// Thin helpers over the C Accessibility API. AXUIElement values never leave the capture queue.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute) ?? ""
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Chromium exposes the DOM class list, which is far more stable than roles alone.
    static func classes(_ element: AXUIElement) -> [String] {
        (attribute(element, "AXDOMClassList") as? [String]) ?? []
    }

    static func domID(_ element: AXUIElement) -> String? {
        string(element, "AXDOMIdentifier")
    }

    /// Frame in AX coordinates: global, top-left origin.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: position, size: size)
    }

    /// Converts a top-left-origin AX rect to AppKit's bottom-left-origin global coordinates.
    static func appKitRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Depth-first search for the first element whose class list contains `className`.
    static func first(
        in root: AXUIElement, withClass className: String, maxDepth: Int = 60,
        skip: (AXUIElement, [String]) -> Bool = { _, _ in false }
    ) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast() {
            let classes = classes(element)
            if classes.contains(className) { return element }
            if depth >= maxDepth || skip(element, classes) { continue }
            for child in children(element).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return nil
    }
}
