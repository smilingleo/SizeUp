import Carbon.HIToolbox
import Foundation

/// Registers global keyboard shortcuts through Carbon.
///
/// One `EventHandler` is installed for the process; each hotkey gets a unique
/// numeric id used to look up its handler when the event arrives. The Carbon
/// handles themselves live in `CarbonHandles` rather than directly on this
/// class — see that type's documentation for why.
@MainActor
public final class HotkeyManager {
    /// Owns the Carbon handles so that teardown is guaranteed by ARC rather
    /// than relying on a caller remembering to call `unregisterAll()`. If a
    /// `HotkeyManager` were ever deallocated without an explicit
    /// `unregisterAll()`, and the Carbon `EventHandlerRef`/`userData` lived
    /// directly on `HotkeyManager`, the installed handler and its `userData`
    /// pointer would outlive the object — the next hotkey press would then
    /// dereference freed memory, and the hotkey would stay claimed
    /// system-wide until logout.
    ///
    /// `HotkeyManager` is `@MainActor`, so it cannot have a `deinit` that
    /// calls its own (actor-isolated) `unregisterAll()`; Swift 6 rejects that
    /// as a synchronous call into actor-isolated code from a nonisolated
    /// context. Moving the handles into this separate, deliberately
    /// non-isolated class lets ARC call `deinit` -> cleanup at the moment the
    /// last strong reference (held by `HotkeyManager`) goes away, whether
    /// that happens via an explicit `unregisterAll()` or via ordinary
    /// deallocation. `UnregisterEventHotKey`/`RemoveEventHandler` are safe to
    /// call from any thread, so no actor isolation is needed here.
    ///
    /// The Carbon event callback also receives a pointer to *this* object
    /// (not to `HotkeyManager`) as `userData`, so the pointer stays valid for
    /// exactly as long as the callback could fire: `CarbonHandles.deinit`
    /// removes the event handler before the object's memory is released.
    fileprivate final class CarbonHandles {
        struct Registration {
            let ref: EventHotKeyRef
            let handler: @MainActor () -> Void
        }

        var registrations: [UInt32: Registration] = [:]
        var eventHandler: EventHandlerRef?

        /// Looks up the handler for a hotkey id. Called from the C callback,
        /// which may run on a thread the compiler cannot prove is the main
        /// actor — this lookup itself does not touch actor-isolated state,
        /// only this plain, non-isolated dictionary.
        func handler(for id: UInt32) -> (@MainActor () -> Void)? {
            registrations[id]?.handler
        }

        func removeAll() {
            for registration in registrations.values {
                UnregisterEventHotKey(registration.ref)
            }
            registrations.removeAll()
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
        }

        deinit {
            removeAll()
        }
    }

    private let handles = CarbonHandles()
    private var claimed: Set<Shortcut> = []
    private var nextID: UInt32 = 1

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

        handles.registrations[id] = CarbonHandles.Registration(ref: ref, handler: handler)
        claimed.insert(shortcut)
        return true
    }

    public func unregisterAll() {
        handles.removeAll()
        claimed.removeAll()
        registrationFailures.removeAll()
    }

    private static let signature: OSType = 0x53_5A_55_50  // 'SZUP'

    private func installEventHandlerIfNeeded() {
        guard handles.eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // userData points at `handles`, not at `self`: its lifetime is tied
        // to the Carbon registrations it owns, so the pointer stays valid
        // for exactly as long as the installed handler could fire.
        let context = Unmanaged.passUnretained(handles).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventCallback,
            1,
            &spec,
            context,
            &handles.eventHandler
        )
    }
}

/// C callback for hotkey presses. Recovers the `CarbonHandles` from
/// `userData`, looks up the handler by hotkey id, then hops to the main
/// actor before invoking it.
///
/// This does NOT use `MainActor.assumeIsolated`: `InstallEventHandler` on the
/// application event target is documented as delivering on the run loop the
/// handler was installed from, which today is the main run loop — but that
/// is a long-standing convention, not a guarantee enforced by the API.
/// `assumeIsolated` does not degrade gracefully if the assumption is ever
/// wrong; it traps and crashes the app. `DispatchQueue.main.async` instead
/// hops to the main actor unconditionally, correct regardless of which
/// thread the callback actually arrives on, at the cost of one imperceptible
/// run-loop turnaround before the window moves.
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

    let handles = Unmanaged<HotkeyManager.CarbonHandles>.fromOpaque(userData).takeUnretainedValue()
    guard let handler = handles.handler(for: hotKeyID.id) else { return noErr }
    DispatchQueue.main.async {
        handler()
    }
    return noErr
}
