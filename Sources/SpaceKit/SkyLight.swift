import Foundation

/// Every private SkyLight symbol this project touches, resolved once via
/// `dlopen`/`dlsym`. Every property is optional: a symbol missing on some
/// future macOS must degrade the specific feature it backs, never crash —
/// see "Risks specific to this milestone" in the M5 plan. `unsafeBitCast` to
/// a `@convention(c)` type will accept anything, so getting a signature
/// wrong here is a crash, not a compile error; every typealias below states
/// the signature it asserts and the probe that exercised it.
///
/// `SpaceKit` is the only target in the project allowed to touch private
/// API, so the blast radius of a macOS change to any one of these symbols is
/// this file.
struct SkyLight: Sendable {
    // SLSMainConnectionID() -> Int32
    // Resolved and called successfully in
    // .superpowers/sdd/2026-08-14-sizeup2-m4/probe.swift, move.swift and
    // follow.swift.
    //
    // `CGS`-prefixed names are the older spelling and are tried second
    // everywhere below. That they are the SAME function, and not merely a
    // similarly named one with a possibly different signature, was measured
    // rather than assumed: `dlsym` returns an identical address for all five
    // pairs on this machine, so the fallback path cannot be called with the
    // wrong signature even though no test exercises it. `SLSManagedDisplay-
    // SetCurrentSpace` was missing its alias until that check found it.
    typealias ConnectionIDFn = @convention(c) () -> Int32

    // SLSCopyManagedDisplaySpaces(connection) -> CFArray?
    // Returns a plist-shaped array of per-display dictionaries. Probed in
    // probe.swift, where it was cast to `[[String: Any]]` and walked.
    typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?

    // SLSMoveWindowsToManagedSpace(connection, windowIDs, spaceID) -> Void
    // Verified in move.swift to actually relocate a window: read back with
    // SLSCopySpacesForWindows before and after, the window's space changed.
    typealias MoveWindowsToManagedSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Void

    // SLSCopySpacesForWindows(connection, selector, windowIDs) -> CFArray?
    // `selector` 0x7 selects all spaces a window occupies, per move.swift,
    // where it was used for the before/after read that proved the move
    // above actually worked.
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    // SLSManagedDisplaySetCurrentSpace(connection, displayUUID, spaceID) -> Void
    // Verified in follow.swift to switch the active space and switch back.
    typealias ManagedDisplaySetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    let connectionID: ConnectionIDFn?
    let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    let moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn?
    let copySpacesForWindows: CopySpacesForWindowsFn?
    let managedDisplaySetCurrentSpace: ManagedDisplaySetCurrentSpaceFn?

    /// Resolved once at process startup, not per call: `dlopen`/`dlsym` are
    /// cheap but there is no reason to repeat them, and a single `let`
    /// makes "is this feature available at all" a single readable check.
    static let shared = SkyLight()

    /// Test-only seam: builds a `SkyLight` from already-resolved (or
    /// deliberately absent) function pointers, so `SpaceKitTests` can pin
    /// exactly which single symbol being missing degrades which behaviour,
    /// without needing a `dlopen` handle that lacks just one symbol.
    init(
        connectionID: ConnectionIDFn?,
        copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?,
        moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn?,
        copySpacesForWindows: CopySpacesForWindowsFn?,
        managedDisplaySetCurrentSpace: ManagedDisplaySetCurrentSpaceFn?
    ) {
        self.connectionID = connectionID
        self.copyManagedDisplaySpaces = copyManagedDisplaySpaces
        self.moveWindowsToManagedSpace = moveWindowsToManagedSpace
        self.copySpacesForWindows = copySpacesForWindows
        self.managedDisplaySetCurrentSpace = managedDisplaySetCurrentSpace
    }

    init(handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW
    )) {
        func resolve(_ names: [String]) -> UnsafeMutableRawPointer? {
            guard let handle else { return nil }
            for name in names {
                if let pointer = dlsym(handle, name) { return pointer }
            }
            return nil
        }

        connectionID = resolve(["SLSMainConnectionID", "CGSMainConnectionID"]).map {
            unsafeBitCast($0, to: ConnectionIDFn.self)
        }
        copyManagedDisplaySpaces = resolve(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"]).map {
            unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self)
        }
        moveWindowsToManagedSpace = resolve(["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"]).map {
            unsafeBitCast($0, to: MoveWindowsToManagedSpaceFn.self)
        }
        copySpacesForWindows = resolve(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"]).map {
            unsafeBitCast($0, to: CopySpacesForWindowsFn.self)
        }
        managedDisplaySetCurrentSpace = resolve(["SLSManagedDisplaySetCurrentSpace", "CGSManagedDisplaySetCurrentSpace"]).map {
            unsafeBitCast($0, to: ManagedDisplaySetCurrentSpaceFn.self)
        }
    }
}
