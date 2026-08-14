import Carbon.HIToolbox
import Foundation

/// Registers global keyboard shortcuts through Carbon.
///
/// One `EventHandler` is installed for the process; each hotkey gets a unique
/// numeric id used to look up its handler when the event arrives.
@MainActor
public final class HotkeyManager {
    private struct Registration {
        let ref: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var claimed: Set<Shortcut> = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// Shortcuts that could not be registered, usually because another
    /// application or the system already owns them.
    public private(set) var registrationFailures: [Shortcut] = []

    public init() {}

    /// Registers `shortcut`, calling `handler` on the main actor when pressed.
    /// - Returns: `true` on success. On failure the shortcut is appended to
    ///   `registrationFailures` so the UI can surface it.
    @discardableResult
    public func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) -> Bool {
        installEventHandlerIfNeeded()

        guard !claimed.contains(shortcut) else {
            registrationFailures.append(shortcut)
            return false
        }

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            registrationFailures.append(shortcut)
            return false
        }

        registrations[id] = Registration(ref: ref, handler: handler)
        claimed.insert(shortcut)
        return true
    }

    public func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        claimed.removeAll()
        registrationFailures.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func handle(id: UInt32) {
        registrations[id]?.handler()
    }

    private static let signature: OSType = 0x53_5A_55_50  // 'SZUP'

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventCallback,
            1,
            &spec,
            context,
            &eventHandler
        )
    }
}

/// C callback for hotkey presses. Recovers the manager from `userData` and
/// dispatches by hotkey id.
private let hotkeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        manager.handle(id: id)
    }
    return noErr
}
