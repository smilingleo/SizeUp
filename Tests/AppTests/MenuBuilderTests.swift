import AppKit
import Core
import Geometry
import Hotkeys
import Testing
@testable import App

// The menu now shows each action's shortcut. The interesting part is not that a
// string appears, but *which* string: it has to be the shortcut in force, not
// the default, and it must not be bound as a real key equivalent.

@MainActor
private func buildMenu(overrides: [(Shortcut?, Action)] = [],
                       mode: CaptureMode = .idle) -> NSMenu {
    var bindings = DefaultKeymap.bindings.map {
        ResolvedBinding(action: $0.1, shortcut: $0.0)
    }
    for (shortcut, action) in overrides {
        if let index = bindings.firstIndex(where: { $0.action == action }) {
            bindings[index] = ResolvedBinding(action: action, shortcut: shortcut)
        }
    }
    let context = MenuBuilder.Context(
        keymap: Resolution(bindings: bindings, conflicts: [:]),
        hasAccessibility: true,
        handlerInstallFailed: false,
        registrationFailures: [],
        sessionMode: mode)
    return MenuBuilder().build(context, target: NSObject())
}

/// Every row's visible text, including the accelerator column.
@MainActor
private func text(of item: NSMenuItem) -> String {
    item.attributedTitle?.string ?? item.title
}

@MainActor
private func row(_ menu: NSMenu, containing fragment: String) -> NSMenuItem? {
    for item in menu.items {
        if text(of: item).contains(fragment) { return item }
        if let sub = item.submenu, let found = row(sub, containing: fragment) {
            return found
        }
    }
    return nil
}

@MainActor
@Test func captureRowsShowTheirShortcut() throws {
    let menu = buildMenu()
    let screenshot = row(menu, containing: "Screenshot")
    #expect(text(of: try #require(screenshot)).contains("⌃⌘A"))
    let record = row(menu, containing: "Record Screen")
    #expect(text(of: try #require(record)).contains("⌃⌘Z"))
}

@MainActor
@Test func windowRowsInsideSubmenusShowTheirShortcutToo() throws {
    // The submenus are where most of the actions live; a column only on the
    // top-level rows would be worse than none.
    let menu = buildMenu()
    let left = try #require(row(menu, containing: "Left Half"))
    #expect(text(of: left).contains("⌃⌥"), "no accelerator on \(text(of: left))")
}

@MainActor
@Test func theShortcutShownIsTheOneInForceNotTheDefault() throws {
    // The whole point: a user who rebound an action must see *their* keys. Using
    // DefaultKeymap here instead of the resolved keymap would look right in
    // testing and be wrong for exactly the people who care.
    let mine = Shortcut(keyCode: 11, modifierFlags: 1 << 20 | 1 << 19) // ⌘⌥B
    let menu = buildMenu(overrides: [(mine, .captureScreenshot)])
    let item = try #require(row(menu, containing: "Screenshot"))
    #expect(text(of: item).contains(mine.displayString))
    #expect(!text(of: item).contains("⌃⌘A"))
}

@MainActor
@Test func anUnboundActionShowsNoAcceleratorButStillSaysSo() throws {
    // "(no shortcut)" is the existing honesty; it must not be joined by an empty
    // accelerator column.
    let menu = buildMenu(overrides: [(nil, .captureScreenshot)])
    let item = try #require(row(menu, containing: "Screenshot"))
    #expect(text(of: item).contains("no shortcut"))
    #expect(item.attributedTitle == nil,
            "an unbound row should not get an accelerator column")
}

@MainActor
@Test func theAcceleratorIsNotBoundAsAKeyEquivalent() throws {
    // These shortcuts are registered globally with Carbon. A real key equivalent
    // would ALSO fire the row while the menu was open, so one press would take
    // two screenshots, or start and immediately stop a recording. The column is
    // drawn, not bound.
    let menu = buildMenu()
    func check(_ menu: NSMenu) {
        for item in menu.items {
            if (item.representedObject as? ActionBox)?.action != nil {
                #expect(item.keyEquivalent.isEmpty,
                        "\(text(of: item)) bound a key equivalent")
            }
            if let sub = item.submenu { check(sub) }
        }
    }
    check(menu)
}

@MainActor
@Test func theAcceleratorSitsInItsOwnRightAlignedColumn() throws {
    // A tab, with a right tab stop, is what lines the column up. Without the tab
    // the shortcut would run straight into the title.
    let menu = buildMenu()
    let item = try #require(row(menu, containing: "Record Screen"))
    let title = try #require(item.attributedTitle)
    #expect(title.string.contains("\t"))

    var range = NSRange()
    let style = title.attribute(.paragraphStyle, at: 0, effectiveRange: &range)
        as? NSParagraphStyle
    let stops = try #require(style?.tabStops)
    #expect(stops.count == 1)
    #expect(stops.first?.alignment == .right)
    #expect((stops.first?.location ?? 0) > 0)
}

@MainActor
@Test func theStopRecordingRowKeepsTheRecordShortcut() throws {
    // Stopping is the same toggle, so it shows the same keys -- not a blank
    // column, and not a second invented binding.
    let menu = buildMenu(mode: .recording)
    let item = try #require(row(menu, containing: "Stop Recording"))
    #expect(text(of: item).contains("⌃⌘Z"))
}

@MainActor
@Test func thereIsNoScrollCaptureRowLeft() throws {
    // The feature is gone; a row that only apologised for itself was worse than
    // no row.
    #expect(row(buildMenu(), containing: "Scroll") == nil)
}
