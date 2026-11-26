import Carbon
import AppKit

/// Registers a global shortcut and handles key release and auto-repeat.
@MainActor
final class GlobalMinimizeHotKeyMonitor {
    private let signature: OSType = 0x54444D4E // TDMN
    private let id: UInt32
    private var registeredKeyCode: UInt32?
    private let onTrigger: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var isPressed = false
    private var releaseTimer: Timer?

    init(id: UInt32 = 1, onTrigger: @escaping () -> Void) {
        self.id = id
        self.onTrigger = onTrigger
    }

    @discardableResult
    func start(keyCode: UInt32, modifiers: UInt32) -> Bool {
        stop()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID(signature: 0, id: 0)
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr, hotKeyID.signature == 0x54444D4E else {
                    return OSStatus(eventNotHandledErr)
                }
                let monitor = Unmanaged<GlobalMinimizeHotKeyMonitor>
                    .fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.id == monitor.id else { return OSStatus(eventNotHandledErr) }
                let kind = GetEventKind(event)
                Task { @MainActor in monitor.handle(kind: kind) }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { return false }

        var registeredHotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        guard RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &registeredHotKey
        ) == noErr, let registeredHotKey else {
            stop()
            return false
        }
        registeredKeyCode = keyCode
        hotKey = registeredHotKey
        return true
    }

    private func handle(kind: UInt32) {
        guard hotKey != nil, let registeredKeyCode else { return }
        if kind == UInt32(kEventHotKeyReleased) {
            isPressed = false
            releaseTimer?.invalidate()
            releaseTimer = nil
        } else if kind == UInt32(kEventHotKeyPressed), !isPressed {
            isPressed = true
            releaseTimer?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Carbon can miss release when Option is released before the shortcut key.
                    if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(registeredKeyCode)) {
                        self.isPressed = false
                        self.releaseTimer?.invalidate()
                        self.releaseTimer = nil
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            releaseTimer = timer
            onTrigger()
        }
    }

    func stop() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredKeyCode = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        isPressed = false
    }
}
