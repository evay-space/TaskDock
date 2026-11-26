import AppKit
import SwiftUI

extension View {
    func floatingBubbleWindow<Content: View>(isPresented: Binding<Bool>, anchorOffset: CGSize = .zero,
                                            anchorSize: CGSize? = nil, locksPositionWhileVisible: Bool = false,
                                            @ViewBuilder content: () -> Content) -> some View {
        background(LeadingArrowPopoverAnchor(isPresented: isPresented, content: AnyView(content()),
            anchorOffset: anchorOffset, anchorSize: anchorSize, locksPositionWhileVisible: locksPositionWhileVisible))
    }
    func floatingBubbleContextMenu(actions: @autoclosure @escaping () -> [FavoriteShelfMenuAction],
                                   iconCenterX: CGFloat? = nil, onIconClick: (() -> Void)? = nil,
                                   onVisibilityChange: @escaping (Bool) -> Void) -> some View {
        modifier(FloatingBubbleContextMenuModifier(actions: actions, iconCenterX: iconCenterX,
            onIconClick: onIconClick, onVisibilityChange: onVisibilityChange))
    }
}

/// Shared window rows for collapsed groups in both taskbar layouts.
struct FloatingBubbleWindowChoiceRow: View {
    let title: String
    var profileAvatar: EdgeProfileAvatar? = nil
    let isMinimized: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    if let profileAvatar {
                        EdgeProfileAvatarBadge(avatar: profileAvatar, size: 16)
                            .equatable()
                    }
                    Text(title).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isMinimized { Image(systemName: "minus.circle") }
                    if isFocused { Image(systemName: "checkmark") }
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .help(title)
            .accessibilityLabel("切换到窗口：\(title)")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(isHovered ? Color.white : Color.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .help("关闭窗口")
            .accessibilityLabel("关闭窗口：\(title)")
        }
        .buttonStyle(.plain)
        .dockMenuFocusAppearance()
        .padding(.horizontal, 9)
        .foregroundStyle(isHovered ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isHovered ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .background(TaskbarPointerHoverTracker { isHovered = $0 })
        .onHover { isHovered = $0 }
    }
}

private struct FloatingBubbleContextMenuModifier: ViewModifier {
    let actions: () -> [FavoriteShelfMenuAction]
    let iconCenterX: CGFloat?
    let onIconClick: (() -> Void)?
    let onVisibilityChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content.overlay(FloatingBubbleContextAnchor(actions: actions, iconCenterX: iconCenterX,
            onClick: onIconClick, onVisibilityChange: onVisibilityChange))
    }
}

private struct FloatingBubbleContextAnchor: NSViewRepresentable {
    let actions: () -> [FavoriteShelfMenuAction]
    let iconCenterX: CGFloat?
    let onClick: (() -> Void)?
    let onVisibilityChange: (Bool) -> Void
    func makeNSView(context: Context) -> ContextView { ContextView() }
    func updateNSView(_ view: ContextView, context: Context) {
        view.actions = actions
        view.iconCenterX = iconCenterX
        view.onVisibilityChange = onVisibilityChange
        view.onClick = onClick
        view.updateClickMonitor()
    }
    static func dismantleNSView(_ view: ContextView, coordinator: ()) {
        view.stopClickMonitor()
        view.presenter.close()
    }

    final class ContextView: NSView {
        private final class WeakBox {
            weak var view: ContextView?
            init(_ view: ContextView) { self.view = view }
        }
        private static var monitoredViews: [ObjectIdentifier: WeakBox] = [:]
        private static var sharedClickMonitor: Any?
        private static weak var activeMenu: ContextView?
        let presenter = LeadingArrowPopoverAnchor.Coordinator()
        var actions: () -> [FavoriteShelfMenuAction] = { [] }
        var iconCenterX: CGFloat?
        var onVisibilityChange: ((Bool) -> Void)?
        var onClick: (() -> Void)?
        private var isRegisteredForClicks = false
        private var pressStart: CGPoint?
        private var holdTimer: Timer?
        private var openedByHold = false

        deinit {
            stopClickMonitor()
            presenter.close()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateClickMonitor()
        }

        private static func installSharedMonitorIfNeeded() {
            guard sharedClickMonitor == nil, !monitoredViews.isEmpty else { return }
            sharedClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { event in
                var currentEvent: NSEvent? = event
                var deadKeys: [ObjectIdentifier] = []
                for (key, box) in monitoredViews {
                    guard let view = box.view else {
                        deadKeys.append(key)
                        continue
                    }
                    guard let activeEvent = currentEvent else { break }
                    currentEvent = view.trackClick(activeEvent)
                }
                for key in deadKeys { monitoredViews.removeValue(forKey: key) }
                if monitoredViews.isEmpty, let monitor = sharedClickMonitor {
                    NSEvent.removeMonitor(monitor)
                    sharedClickMonitor = nil
                }
                return currentEvent
            }
        }

        func updateClickMonitor() {
            guard window != nil, onClick != nil else { stopClickMonitor(); return }
            guard !isRegisteredForClicks else { return }
            isRegisteredForClicks = true
            Self.monitoredViews[ObjectIdentifier(self)] = WeakBox(self)
            Self.installSharedMonitorIfNeeded()
        }

        func stopClickMonitor() {
            if isRegisteredForClicks {
                isRegisteredForClicks = false
                Self.monitoredViews.removeValue(forKey: ObjectIdentifier(self))
                if Self.monitoredViews.isEmpty, let monitor = Self.sharedClickMonitor {
                    NSEvent.removeMonitor(monitor)
                    Self.sharedClickMonitor = nil
                }
            }
            cancelHold()
            openedByHold = false
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
            pressStart = nil
        }

        private func trackClick(_ event: NSEvent) -> NSEvent? {
            if event.type == .leftMouseUp, openedByHold {
                openedByHold = false
                cancelHold()
                return nil
            }

            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else {
                cancelHold()
                return event
            }
            switch event.type {
            case .leftMouseDown:
                cancelHold()
                guard !event.modifierFlags.contains(.control),
                      bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else { return event }
                pressStart = event.locationInWindow
                let timer = Timer(timeInterval: FavoriteShelfInteractionMetrics.holdDuration, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let start = self.pressStart,
                              NSEvent.pressedMouseButtons & 1 != 0,
                              let window = self.window, !self.isHiddenOrHasHiddenAncestor else {
                            self?.cancelHold()
                            return
                        }
                        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                        guard hypot(pointInWindow.x - start.x, pointInWindow.y - start.y) < FavoriteShelfInteractionMetrics.holdMovementTolerance,
                              self.bounds.intersection(self.visibleRect).contains(self.convert(pointInWindow, from: nil)) else {
                            self.cancelHold()
                            return
                        }
                        self.openedByHold = true
                        self.showMenu()
                    }
                }
                holdTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            case .leftMouseDragged, .leftMouseUp:
                guard let start = pressStart else { break }
                let delta = CGPoint(x: event.locationInWindow.x - start.x, y: event.locationInWindow.y - start.y)
                let distance = hypot(delta.x, delta.y)
                if distance >= FavoriteShelfInteractionMetrics.holdMovementTolerance {
                    holdTimer?.invalidate()
                    holdTimer = nil
                }
                if distance >= FavoriteShelfInteractionMetrics.dragDistance {
                    cancelHold()
                } else if event.type == .leftMouseUp {
                    cancelHold()
                    let open = onClick
                    DispatchQueue.main.async { open?() }
                    return nil
                }
            default:
                break
            }
            return event
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) { rightMouseDown(with: event) }
        override func rightMouseDown(with event: NSEvent) { showMenu() }

        func showMenu() {
            let actions = actions()
            guard !actions.isEmpty else { return }
            if Self.activeMenu !== self {
                Self.activeMenu?.cancelHold()
                Self.activeMenu?.presenter.close()
            }
            Self.activeMenu = self
            presenter.close()
            presenter.dismiss = { [weak self] in self?.presenter.close() }
            presenter.didClose = { [weak self] in
                if Self.activeMenu === self { Self.activeMenu = nil }
                self?.onVisibilityChange?(false)
            }
            presenter.shouldShow = true
            presenter.show(AnyView(FloatingBubbleActionList(actions: actions) { [weak self] action in
                self?.presenter.close()
                action()
            }), relativeTo: self, iconCenterX: iconCenterX)
            onVisibilityChange?(true)
        }
    }
}

private struct FloatingBubbleActionList: View {
    let actions: [FavoriteShelfMenuAction]
    let onSelect: (() -> Void) -> Void
    @State private var hovered: Int?
    var body: some View {
        VStack(spacing: 0) {
            ForEach(actions.indices, id: \.self) { index in
                let action = actions[index]
                if let title = action.title, let perform = action.perform {
                    Button { onSelect(perform) } label: {
                        HStack(spacing: 8) {
                            if let symbol = action.symbol { Image(systemName: symbol).frame(width: 16) }
                            Text(title)
                            Spacer(minLength: 0)
                        }.font(.system(size: 13)).padding(.horizontal, 9).frame(height: 29)
                            .foregroundStyle(hovered == index ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6).fill(hovered == index ? Color.accentColor : .clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).dockMenuFocusAppearance().disabled(!action.isEnabled)
                        .onHover { hovered = $0 ? index : nil }
                } else { Divider().padding(.horizontal, 9).padding(.vertical, 5) }
            }
        }.padding(5).frame(width: 240)
    }
}

private struct LeadingArrowPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: AnyView
    let anchorOffset: CGSize
    let anchorSize: CGSize?
    let locksPositionWhileVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { AnchorView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.dismiss = { isPresented = false }
        coordinator.shouldShow = isPresented
        if isPresented {
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator, coordinator.shouldShow, view.window != nil else { return }
                coordinator.show(content, relativeTo: view, anchorOffset: anchorOffset, anchorSize: anchorSize,
                    locksPositionWhileVisible: locksPositionWhileVisible)
            }
        } else { coordinator.close() }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.close() }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var dismiss: (() -> Void)?
        var shouldShow = false
        var didClose: (() -> Void)?
        private var panel: ArrowPanel?
        private var localMonitor: Any?
        private var globalMonitor: Any?
        private var anchorHitRect = CGRect.zero
        private var panelArrowX: CGFloat?
        private var parentMoveObserver: NSObjectProtocol?

        func show(_ content: AnyView, relativeTo anchor: NSView, iconCenterX: CGFloat? = nil,
                  anchorOffset: CGSize = .zero, anchorSize: CGSize? = nil, locksPositionWhileVisible: Bool = false) {
            guard let parent = anchor.window, parent.isVisible, !parent.isMiniaturized,
                  !anchor.isHiddenOrHasHiddenAncestor else { close(); return }
            let restingRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let size = anchorSize ?? restingRect.size
            let rect = CGRect(x: restingRect.midX + anchorOffset.width - size.width / 2,
                y: restingRect.midY + anchorOffset.height - size.height / 2,
                width: size.width, height: size.height)
            anchorHitRect = rect
            if locksPositionWhileVisible, let panelArrowX,
               let hosting = panel?.contentView as? NSHostingView<AnyView> {
                hosting.rootView = AnyView(FloatingBubbleSurface(arrowX: panelArrowX) { content })
                return
            }
            let targetX = iconCenterX.map { offset in
                parent.convertPoint(toScreen: anchor.convert(NSPoint(
                    x: anchor.bounds.minX + min(max(offset, 0), anchor.bounds.width),
                    y: anchor.bounds.midY), to: nil)).x
            } ?? rect.midX
            let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? rect.insetBy(dx: -500, dy: -500)
            let host = NSHostingView(rootView: content)
            let fittingSize = host.fittingSize
            let width = max(260, min(fittingSize.width, visible.width - 16))
            let height = fittingSize.height + 10
            let x = min(max(targetX - 30, visible.minX + 8), visible.maxX - width - 8)
            let arrowX = min(max(targetX - x, 18), width - 18)
            panelArrowX = arrowX
            let y = min(rect.maxY + 14, visible.maxY - height - 8)
            let root = AnyView(FloatingBubbleSurface(arrowX: arrowX) { content })
            if let existing = panel, let hosting = existing.contentView as? NSHostingView<AnyView> {
                hosting.rootView = root
                existing.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
                return
            }
            let window = ArrowPanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .popUpMenu
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.dismiss = { [weak self] in self?.dismiss?() }
            window.contentView = NSHostingView(rootView: root)
            panel = window
            parent.addChildWindow(window, ordered: .above)
            if locksPositionWhileVisible {
                let origin = window.frame.origin
                parentMoveObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: parent, queue: .main
                ) { [weak window] _ in
                    // AppKit moves child windows along with the taskbar panel.
                    if let window, window.frame.origin != origin { window.setFrameOrigin(origin) }
                }
            }
            window.makeKeyAndOrderFront(nil)
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53 { self.dismiss?(); return nil }
                if event.type != .keyDown, event.window !== self.panel,
                   !self.anchorHitRect.contains(NSEvent.mouseLocation) { self.dismiss?() }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismiss?()
            }
        }
        func close() {
            let wasOpen = panel != nil
            shouldShow = false
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil; globalMonitor = nil
            if let parentMoveObserver { NotificationCenter.default.removeObserver(parentMoveObserver) }
            parentMoveObserver = nil
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
            panel = nil
            panelArrowX = nil
            if wasOpen { didClose?() }
        }
        deinit { close() }
    }
}

private final class ArrowPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

struct FloatingBubbleSurface<Content: View>: View {
    let arrowX: CGFloat
    var isSmall = false
    @ViewBuilder let content: () -> Content
    @AppStorage(DeveloperDebugSettings.bubbleTransparencyKey) private var transparency = 0.0
    @AppStorage(DeveloperDebugSettings.largeBubbleGlassStrengthKey) private var largeBubbleGlassStrength = 1.0
    @Environment(\.colorScheme) private var colorScheme
    private var tintOpacity: Double {
        let adjustment = transparency.isFinite ? min(0.9, max(0, transparency)) : 0
        let baseOpacity = colorScheme == .light ? (isSmall ? 0.23 : 0.25) : (isSmall ? 0.12 : 0.14)
        return baseOpacity * (1 - adjustment / 0.9)
    }
    private var glassOpacity: Double {
        guard !isSmall else { return 1 }
        let strength = largeBubbleGlassStrength.isFinite ? min(1, max(0, largeBubbleGlassStrength)) : 1
        return 0.8 + 0.2 * strength
    }
    var body: some View {
        content().padding(.bottom, isSmall ? SmallBubbleMetrics.tailHeight : 10)
            .background {
                FrostedBubbleBackground(arrowX: arrowX, isSmall: isSmall, glassOpacity: glassOpacity)
                    .overlay {
                        FloatingBubbleShape(arrowX: arrowX, isSmall: isSmall)
                            .fill((colorScheme == .light ? Color.white : Color(nsColor: .windowBackgroundColor))
                                .opacity(tintOpacity))
                    }
            }
            .overlay(FloatingBubbleShape(arrowX: arrowX, isSmall: isSmall).stroke(Color.primary.opacity(0.26), lineWidth: 0.5))
    }
}

/// Compact capsule hints share the glass material while keeping their own outline.
enum SmallBubbleMetrics {
    static var fontSize: CGFloat { value(DeveloperDebugSettings.smallBubbleFontSizeKey, fallback: 12, range: 9...20) }
    static var iconGap: CGFloat { value(DeveloperDebugSettings.smallBubbleIconGapKey, fallback: 3, range: 0...30) }
    static let textVerticalPadding: CGFloat = 12
    static let tailHeight: CGFloat = 6
    static var height: CGFloat { fontSize + textVerticalPadding + tailHeight }
    static func width(for title: String, sizeScale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        return min(280 * sizeScale, ceil(textWidth) + 28)
    }

    static func placement(width: CGFloat, iconCenter: CGFloat,
                          horizontalBounds: ClosedRange<CGFloat>) -> (left: CGFloat, arrow: CGFloat) {
        let left = min(max(iconCenter - width / 2, horizontalBounds.lowerBound),
            max(horizontalBounds.lowerBound, horizontalBounds.upperBound - width))
        return (left, iconCenter - left)
    }

    private static func value(_ key: String, fallback: Double, range: ClosedRange<Double>) -> CGFloat {
        let number = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
        return CGFloat(number.isFinite ? min(range.upperBound, max(range.lowerBound, number)) : fallback)
    }
}

final class FloatingBubbleHintView: NSHostingView<AnyView> {
    private var previous: (String, CGFloat, CGFloat, CGFloat)?
    private var appearanceObserver: NSObjectProtocol?
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        followSystemAppearance()
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.followSystemAppearance() }
        }
    }
    convenience init(title: String, width: CGFloat, fontSize: CGFloat, arrowX: CGFloat) {
        self.init(rootView: AnyView(EmptyView()))
        update(title: title, width: width, fontSize: fontSize, arrowX: arrowX)
    }
    @MainActor required dynamic init?(coder: NSCoder) { nil }
    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func followSystemAppearance() {
        appearance = NSApp.effectiveAppearance
    }
    func update(title: String, width: CGFloat, fontSize: CGFloat, arrowX: CGFloat) {
        if let previous, previous.0 == title, previous.1 == width,
           previous.2 == fontSize, previous.3 == arrowX { return }
        followSystemAppearance()
        previous = (title, width, fontSize, arrowX)
        rootView = AnyView(FloatingBubbleSurface(arrowX: arrowX, isSmall: true) {
            Text(title).font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(Color.primary).lineLimit(1)
                .frame(width: width, height: fontSize + SmallBubbleMetrics.textVerticalPadding)
        })
    }
}

private struct FrostedBubbleBackground: NSViewRepresentable {
    let arrowX: CGFloat
    var isSmall = false
    var glassOpacity = 1.0
    func makeNSView(context: Context) -> FrostedView {
        let view = FrostedView()
        view.material = isSmall ? .toolTip : .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.alphaValue = glassOpacity
        view.arrowX = arrowX
        view.isSmall = isSmall
        return view
    }
    func updateNSView(_ view: FrostedView, context: Context) {
        view.arrowX = arrowX
        view.isSmall = isSmall
        view.material = isSmall ? .toolTip : .menu
        view.alphaValue = glassOpacity
        view.needsLayout = true
    }
    final class FrostedView: NSVisualEffectView {
        var arrowX: CGFloat = 30
        var isSmall = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            guard bounds.width > 0, bounds.height > 10 else { return }
            let size = bounds.size
            let path = FloatingBubbleShape(arrowX: arrowX, isSmall: isSmall).path(in: CGRect(origin: .zero, size: size)).cgPath
            maskImage = NSImage(size: size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(path)
                context.fillPath()
                return true
            }
        }
    }
}

private struct FloatingBubbleShape: Shape {
    let arrowX: CGFloat
    var isSmall = false
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = isSmall ? SmallBubbleMetrics.tailHeight : 10
        let bottom = rect.maxY - tail
        let r: CGFloat = isSmall ? min(bottom / 2, rect.width / 2) : 12
        let scale: CGFloat = isSmall ? 0.6 : 1
        let a = arrowX
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: r), control: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: bottom - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
        // Horizontal tangents at both shoulders and a rounded tip keep the
        // pointer continuous with the bottom edge instead of looking attached.
        let minimumShoulder: CGFloat = isSmall ? 6 : 12
        let shoulder = min(isSmall ? 11 : 18, max(minimumShoulder, a - r), max(minimumShoulder, rect.maxX - a - r))
        p.addLine(to: CGPoint(x: a + shoulder, y: bottom))
        p.addCurve(to: CGPoint(x: a + 7 * scale, y: bottom + 6 * scale),
                   control1: CGPoint(x: a + shoulder - 6 * scale, y: bottom),
                   control2: CGPoint(x: a + 11 * scale, y: bottom + 2 * scale))
        p.addCurve(to: CGPoint(x: a, y: rect.maxY),
                   control1: CGPoint(x: a + 3 * scale, y: rect.maxY),
                   control2: CGPoint(x: a + 2 * scale, y: rect.maxY))
        p.addCurve(to: CGPoint(x: a - 7 * scale, y: bottom + 6 * scale),
                   control1: CGPoint(x: a - 2 * scale, y: rect.maxY),
                   control2: CGPoint(x: a - 3 * scale, y: rect.maxY))
        p.addCurve(to: CGPoint(x: a - shoulder, y: bottom),
                   control1: CGPoint(x: a - 11 * scale, y: bottom + 2 * scale),
                   control2: CGPoint(x: a - shoulder + 6 * scale, y: bottom))
        p.addLine(to: CGPoint(x: r, y: bottom))
        p.addQuadCurve(to: CGPoint(x: 0, y: bottom - r), control: CGPoint(x: 0, y: bottom))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
        p.closeSubpath()
        return p
    }
}
