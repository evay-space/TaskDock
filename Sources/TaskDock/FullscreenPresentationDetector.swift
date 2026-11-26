import AppKit
import ApplicationServices
import CoreGraphics

/// Full-screen video can use a borderless window instead of AXFullScreen.
/// Window-server bounds cover both cases without treating an ordinary zoomed
/// window (which stops at the menu bar) as full screen.
enum FullscreenPresentationDetector {
    static func isCoveringTaskbarScreen(excludingPID: pid_t, screen: NSScreen?) -> Bool {
        guard let screen,
              let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != excludingPID,
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        let displayFrame = CGDisplayBounds(CGDirectDisplayID(displayNumber.uint32Value))
        guard displayFrame.width > 0, displayFrame.height > 0,
              let entries = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return false }

        let windows = entries.compactMap { entry -> CGRect? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer >= 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.5,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let windowFrame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return windowFrame
        }
        if windows.contains(where: { coversDisplay($0, displayFrame) }) { return true }

        // Some native full-screen windows exclude the menu bar or camera housing
        // from their reported frame. Require AX confirmation for those bounds.
        guard let frame = windows.first(where: { coversDisplay($0, displayFrame, allowingTopInset: true) }),
              AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(frontmostPID)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = focused as! AXUIElement
        var fullscreen: CFTypeRef?
        var position: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success,
              fullscreen as? Bool == true,
              AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              let position, CFGetTypeID(position) == AXValueGetTypeID() else { return false }
        var origin = CGPoint.zero
        return AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            && abs(origin.x - frame.minX) <= 4 && abs(origin.y - frame.minY) <= 4
    }

    static func coversDisplay(_ window: CGRect, _ display: CGRect, allowingTopInset: Bool = false) -> Bool {
        let tolerance: CGFloat = 4
        let topInset = window.minY - display.minY
        return abs(window.minX - display.minX) <= tolerance
            && topInset >= -tolerance && topInset <= (allowingTopInset ? 64 : tolerance)
            && abs(window.maxX - display.maxX) <= tolerance
            && abs(window.maxY - display.maxY) <= tolerance
    }
}
