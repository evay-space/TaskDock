import AppKit
import ObjectiveC.runtime

/// Private appearance experiment is isolated to our nonactivating taskbar panels.
/// Unsupported systems keep NSPanel's original implementation.
class TaskbarAppearancePanel: NSPanel {
    var permitsExperimentalGlass = false
}

enum TaskbarExperimentalGlass {
    static let clarityKey = "taskdock.customGlassClarityV1"

    static func normalizedClarity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }
    private static var appliedManualTint: Double?
    private static var preferenceObserver: NSObjectProtocol?
    private static let systemTintKey = "NSGlassTintAmount"

    /// Override only this process; the saved slider is authoritative even when an
    /// older installation still has the retired follow-system preference.
    static func installPreferenceIsolation() {
        synchronizePreferenceIsolation()
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in synchronizePreferenceIsolation() }
    }

    static func synchronizePreferenceIsolation() {
        guard isSupported else { return }
        let defaults = UserDefaults.standard
        let clarity = (defaults.object(forKey: clarityKey) as? NSNumber)?.doubleValue ?? 1
        let tint = 1 - normalizedClarity(clarity)
        guard appliedManualTint != tint else { return }
        appliedManualTint = tint
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[systemTintKey] = tint
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        refreshNativeMaterial()
    }

    private static func refreshNativeMaterial() {
        NotificationCenter.default.post(
            name: Notification.Name("NSGlassEffectDiffusionDidChangeNotification"), object: nil)
    }

    static var isSupported: Bool { panelType != nil }
    private static let panelType: NSPanel.Type? = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return nil }
        let selector = NSSelectorFromString("_hasActiveAppearance")
        guard let method = class_getInstanceMethod(NSPanel.self, selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding).hasPrefix("B"),
              method_getNumberOfArguments(method) == 2,
              let subclass = objc_allocateClassPair(TaskbarAppearancePanel.self, "TaskDockExperimentalAppearancePanel", 0) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let getter: @convention(block) (AnyObject) -> Bool = { object in
            if let panel = object as? TaskbarAppearancePanel,
               panel.permitsExperimentalGlass { return true }
            return original(object, selector)
        }
        let implementation = imp_implementationWithBlock(getter)
        guard class_addMethod(subclass, selector, implementation, encoding) else {
            imp_removeBlock(implementation)
            objc_disposeClassPair(subclass)
            return nil
        }
        objc_registerClassPair(subclass)
        return subclass as? NSPanel.Type
    }()

    static func makePanel() -> NSPanel {
        (panelType ?? TaskbarAppearancePanel.self).init(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
}


/// Glass is a native sibling beneath the hosting view, never an offscreen SwiftUI image.
final class TaskbarNativeContentView: NSView {
    let hosting: NSView

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: hosting.frame)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { nil }

    func attachGlass(_ glass: NSView) {
        guard glass.superview !== self else { return }
        addSubview(glass, positioned: .below, relativeTo: hosting)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// SwiftUI only places this invisible anchor. AppKit owns the actual glass rendering.
final class TaskbarGlassAnchorView: NSView {
    private var glass: NSView
    private let backdropBlur: NSVisualEffectView?
    private var appliedCornerRadius: CGFloat?
    private var leadingInset: CGFloat = 0
    private var trailingInset: CGFloat = 0
    private let glassMask = CAShapeLayer()
    private let blurMask = CAShapeLayer()
    private var maskedBounds: CGRect?
    private var maskedCornerRadius: CGFloat?

    private static func makeGlass() -> NSView {
        if #available(macOS 26, *) {
            let effect = NSGlassEffectView(frame: .zero)
            effect.style = .clear
            return effect
        } else {
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            return effect
        }
    }

    private static func makeBackdropBlur() -> NSVisualEffectView? {
        guard #available(macOS 26, *) else { return nil }
        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = TaskDockAppearance.fixed
        effect.alphaValue = 0.7
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        return effect
    }

    override init(frame: NSRect) {
        glass = Self.makeGlass()
        backdropBlur = Self.makeBackdropBlur()
        super.init(frame: frame)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(cornerRadius: CGFloat, opacity: Double,
                   leadingInset: CGFloat = 0, trailingInset: CGFloat = 0) {
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        TaskbarExperimentalGlass.synchronizePreferenceIsolation()
        if appliedCornerRadius != cornerRadius {
            appliedCornerRadius = cornerRadius
            if #available(macOS 26, *), let effect = glass as? NSGlassEffectView {
                effect.cornerRadius = cornerRadius
            } else {
                glass.layer?.cornerRadius = cornerRadius
            }
            backdropBlur?.layer?.cornerRadius = cornerRadius
        }
        let alpha = CGFloat(min(1, max(0, opacity)))
        if glass.alphaValue != alpha { glass.alphaValue = alpha }
        synchronizeGlass()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeGlass()
    }

    override func layout() {
        super.layout()
        synchronizeGlass()
    }

    func detachGlass() {
        glass.removeFromSuperview()
        backdropBlur?.removeFromSuperview()
    }

    private func synchronizeGlass() {
        guard let root = window?.contentView as? TaskbarNativeContentView else {
            detachGlass()
            return
        }
        let frame = convert(bounds, to: root)
        let hidden = isHiddenOrHasHiddenAncestor || bounds.isEmpty
        if let backdropBlur {
            root.attachGlass(backdropBlur)
            if backdropBlur.frame != frame { backdropBlur.frame = frame }
            if backdropBlur.isHidden != hidden { backdropBlur.isHidden = hidden }
        }
        root.attachGlass(glass)
        if glass.frame != frame { glass.frame = frame }
        if glass.isHidden != hidden { glass.isHidden = hidden }
        updateMask(canvasSize: frame.size)
    }

    // The visible pill can grow without resizing either native effect view on
    // every display frame. Clip both effects to the same animated outline.
    private func updateMask(canvasSize: CGSize) {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let visible = CGRect(x: leadingInset, y: 0,
            width: max(0, canvas.width - leadingInset - trailingInset), height: canvas.height)
        if visible == canvas {
            if maskedBounds != nil {
                glass.layer?.mask = nil
                backdropBlur?.layer?.mask = nil
                maskedBounds = nil
            }
            return
        }
        let radius = min(appliedCornerRadius ?? 0, visible.width / 2, visible.height / 2)
        let changed = maskedBounds != visible || maskedCornerRadius != radius || glassMask.frame != canvas
        guard changed else { return }
        maskedBounds = visible
        maskedCornerRadius = radius
        let path = CGPath(roundedRect: visible, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glassMask.frame = canvas
        glassMask.path = path
        blurMask.frame = canvas
        blurMask.path = path
        if glass.layer?.mask !== glassMask {
            glass.wantsLayer = true
            glass.layer?.mask = glassMask
        }
        if let backdropBlur, backdropBlur.layer?.mask !== blurMask {
            backdropBlur.layer?.mask = blurMask
        }
        CATransaction.commit()
    }
}
