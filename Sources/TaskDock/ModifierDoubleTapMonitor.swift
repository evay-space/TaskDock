import AppKit

@MainActor
final class ModifierDoubleTapMonitor {
    private let settings: SettingsStore
    private let onDoubleTap: () -> Void
    private let onOptionHoldChanged: (Bool) -> Void
    private let onLongOptionHold: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTapAt: Date?
    private var modifierIsDown = false
    private var optionOnlyIsDown = false
    private var optionHoldIsActive = false
    private var optionHoldTimer: Timer?
    private var optionHoldConsumed = false
    var isOptionShortcutActive: Bool { optionHoldIsActive }

    init(
        settings: SettingsStore,
        onDoubleTap: @escaping () -> Void,
        onOptionHoldChanged: @escaping (Bool) -> Void,
        onLongOptionHold: @escaping () -> Void
    ) {
        self.settings = settings
        self.onDoubleTap = onDoubleTap
        self.onOptionHoldChanged = onOptionHoldChanged
        self.onLongOptionHold = onLongOptionHold
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancelLongOptionHold()
        if optionHoldIsActive { onOptionHoldChanged(false) }
        optionHoldIsActive = false
        optionOnlyIsDown = false
        lastTapAt = nil
        modifierIsDown = false
    }

    func cancelLongOptionHold() {
        optionHoldTimer?.invalidate()
        optionHoldTimer = nil
        optionHoldConsumed = true
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            lastTapAt = nil
            cancelLongOptionHold()
            return
        }

        let desiredFlag = modifierFlag
        let relevantFlags = event.modifierFlags.intersection([.option, .command, .control, .shift])
        let desiredIsDown = relevantFlags.contains(desiredFlag)
        var doubleTapped = false

        if desiredIsDown, !modifierIsDown, relevantFlags == desiredFlag {
            let now = Date()
            if let lastTapAt, now.timeIntervalSince(lastTapAt) <= 0.38 {
                self.lastTapAt = nil
                doubleTapped = true
                onDoubleTap()
            } else {
                lastTapAt = now
            }
        }
        modifierIsDown = desiredIsDown

        let optionOnlyIsDown = relevantFlags == .option
        if optionOnlyIsDown != self.optionOnlyIsDown {
            self.optionOnlyIsDown = optionOnlyIsDown
            if optionOnlyIsDown, !doubleTapped {
                optionHoldIsActive = true
                onOptionHoldChanged(true)
                optionHoldConsumed = false
                let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.optionOnlyIsDown, !self.optionHoldConsumed else { return }
                        self.optionHoldConsumed = true
                        self.optionHoldTimer = nil
                        self.onLongOptionHold()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                optionHoldTimer = timer
            } else if optionHoldIsActive {
                optionHoldIsActive = false
                onOptionHoldChanged(false)
            }
            if !optionOnlyIsDown { cancelLongOptionHold() }
        }
    }

    private var modifierFlag: NSEvent.ModifierFlags {
        switch settings.toggleModifier {
        case .option: return .option
        case .command: return .command
        case .control: return .control
        }
    }
}
