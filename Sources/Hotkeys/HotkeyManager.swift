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

    /// Set once if the process-wide Carbon event handler itself failed to
    /// install. When this is true, `registrationFailures` will already
    /// contain every shortcut ever passed to `register`, since none of them
    /// could possibly fire — but this flag lets callers distinguish "the
    /// event handler itself is broken" from "some individual shortcuts lost
    /// a conflict", which deserves at least as strong a warning.
    public private(set) var handlerInstallFailed = false

    /// Test-only hook: when set, `installEventHandlerIfNeeded` reports
    /// failure without making the real Carbon call, so tests can exercise
    /// the "handler install failed" path without needing Carbon itself to
    /// fail. Not part of the public API.
    internal var forceEventHandlerInstallFailureForTesting = false

    public init() {}

    /// Registers `shortcut`, calling `handler` on the main actor when pressed.
    /// - Returns: `true` on success. On failure the shortcut is appended to
    ///   `registrationFailures` so the UI can surface it.
    @discardableResult
    public func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) -> Bool {
        guard installEventHandlerIfNeeded() else {
            registrationFailures.append(shortcut)
            return false
        }

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
        handlerInstallFailed = false
    }

    private static let signature: OSType = 0x53_5A_55_50  // 'SZUP'

    /// - Returns: `true` if the process-wide event handler is installed,
    ///   whether it already was or was just installed successfully. `false`
    ///   if installation was attempted and failed — in that case no hotkey
    ///   registered afterwards can ever fire, so callers must treat this as
    ///   a hard registration failure rather than silently proceeding.
    private func installEventHandlerIfNeeded() -> Bool {
        guard handles.eventHandler == nil else { return true }
        if forceEventHandlerInstallFailureForTesting {
            handlerInstallFailed = true
            return false
        }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // userData points at `handles`, not at `self`. Its lifetime is not
        // tied to the pointer alone any more: the callback below takes a
        // strong retain on `handles` on this thread — where the object is
        // provably alive because the handler is provably installed — and
        // releases it after the main-actor hop, so a `HotkeyManager`
        // deallocating between delivery and that hop cannot free `handles`
        // out from under the dispatched block. See the callback's comment.
        let context = Unmanaged.passUnretained(handles).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventCallback,
            1,
            &spec,
            context,
            &handles.eventHandler
        )
        guard status == noErr, handles.eventHandler != nil else {
            handles.eventHandler = nil
            handlerInstallFailed = true
            return false
        }
        return true
    }
}

/// C callback for hotkey presses. Retains `CarbonHandles` on this thread,
/// hops to the main actor, then looks up the handler by hotkey id and
/// invokes it. See the inline comments below for why the retain and the
/// deferred dictionary lookup both matter.
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

    // `userData` is `passUnretained`, so nothing keeps `CarbonHandles` alive
    // on its own. On this thread the object is provably alive — Carbon does
    // not invoke this callback after `RemoveEventHandler` returns, and
    // `RemoveEventHandler` only runs from `CarbonHandles.deinit` — so a
    // strong retain taken right here is guaranteed to succeed. A strong
    // reference, not a bare pointer, is what crosses the dispatch boundary:
    // an `Int` bit pattern carries no retain, so if the last reference to
    // the owning `HotkeyManager` dropped between delivery and the main-actor
    // hop, the bare-pointer version would resolve to already-freed memory.
    // The dictionary lookup itself still happens *inside* the dispatched
    // block, not out here: today registration happens once at launch, so
    // reading it on whatever thread Carbon delivers this callback on would
    // be safe by luck, but a later feature that re-registers hotkeys while
    // the app is running would turn a same-thread read here into a live
    // race with a main-actor mutation of `registrations`. Deferring the
    // read to the main actor removes the race entirely, rather than
    // papering over it with a lock.
    let unmanaged = Unmanaged<HotkeyManager.CarbonHandles>.fromOpaque(userData)
    _ = unmanaged.retain()  // +1 while provably alive; balanced below.
    let id = hotKeyID.id
    let rawPointerBits = Int(bitPattern: userData)

    // This does NOT use `MainActor.assumeIsolated`: `InstallEventHandler` on
    // the application event target is documented as delivering on the run
    // loop the handler was installed from, which today is the main run loop
    // — but that is a long-standing convention, not a guarantee enforced by
    // the API. `assumeIsolated` does not degrade gracefully if the
    // assumption is ever wrong; it traps and crashes the app.
    // `DispatchQueue.main.async` instead hops to the main actor
    // unconditionally, correct regardless of which thread the callback
    // actually arrives on, at the cost of one imperceptible run-loop
    // turnaround before the window moves.
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: rawPointerBits) else { return }
        let owned = Unmanaged<HotkeyManager.CarbonHandles>.fromOpaque(pointer)
        defer { owned.release() }  // -1: balances the retain taken above.
        guard let handler = owned.takeUnretainedValue().handler(for: id) else { return }
        handler()
    }
    return noErr
}
