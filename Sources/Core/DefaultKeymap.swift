import Geometry
import Hotkeys

/// The shortcuts this app ships with, matching the user's SizeUp setup.
///
/// The quarter bindings follow SizeUp's default arrow assignment, which runs
/// clockwise from the left arrow rather than mapping arrows to corners
/// spatially: left = upper left, up = upper RIGHT, down = lower LEFT, right =
/// lower right. It looks wrong and is not: it is established muscle memory
/// built over thousands of window moves, and must be reproduced verbatim.
public enum DefaultKeymap {
    private static let ctrlOptCmd: UInt = 1_835_008
    private static let ctrlOptShift: UInt = 917_504
    private static let ctrlOpt: UInt = 786_432
    /// From the author's live SizeUp plist: `ComboFlags` 1310720, which is
    /// Carbon 4352 (`controlKey` 0x1000 | `cmdKey` 0x100) once translated —
    /// control and command, no option.
    private static let ctrlCmd: UInt = 1_310_720

    public static let bindings: [(Shortcut, Action)] = [
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlOptCmd), .half(.left)),
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlOptCmd), .half(.right)),
        (Shortcut(keyCode: KeyCode.upArrow, modifierFlags: ctrlOptCmd), .half(.top)),
        (Shortcut(keyCode: KeyCode.downArrow, modifierFlags: ctrlOptCmd), .half(.bottom)),
        (Shortcut(keyCode: KeyCode.m, modifierFlags: ctrlOptCmd), .fullScreen),
        (Shortcut(keyCode: KeyCode.c, modifierFlags: ctrlOptCmd), .center),
        (Shortcut(keyCode: KeyCode.slash, modifierFlags: ctrlOptCmd), .snapBack),
        // Clockwise-from-left, not spatial — see the type doc above.
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlOptShift), .quarter(.upperLeft)),
        (Shortcut(keyCode: KeyCode.upArrow, modifierFlags: ctrlOptShift), .quarter(.upperRight)),
        (Shortcut(keyCode: KeyCode.downArrow, modifierFlags: ctrlOptShift), .quarter(.lowerLeft)),
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlOptShift), .quarter(.lowerRight)),
        // Next/Previous Display. NOTE these are the same arrows as the halves
        // bindings above, distinguished only by the command modifier — so a
        // dropped command bit here would silently steal the halves shortcuts.
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlOpt), .display(.next)),
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlOpt), .display(.previous)),
        // Next/Previous Space. Same arrows again, distinguished from both the
        // halves and the display moves by the modifier combination — control
        // and command, no option.
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlCmd), .space(.next)),
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlCmd), .space(.previous)),
    ]

    /// Menu label for an action.
    ///
    /// Every direction is spelled out rather than caught by a `case .display:`
    /// fallthrough. The catch-all version labelled `.display(.above)` as
    /// "Previous Display", and an exhaustive switch means a future `Direction`
    /// case fails to compile instead of acquiring a silently wrong label.
    public static func title(for action: Action) -> String {
        switch action {
        case .half(.left): return "Left Half"
        case .half(.right): return "Right Half"
        case .half(.top): return "Top Half"
        case .half(.bottom): return "Bottom Half"
        case .quarter(.upperLeft): return "Upper Left"
        case .quarter(.upperRight): return "Upper Right"
        case .quarter(.lowerLeft): return "Lower Left"
        case .quarter(.lowerRight): return "Lower Right"
        case .center: return "Center"
        case .fullScreen: return "Full Screen"
        case .snapBack: return "Snap Back"
        case .display(.next): return "Next Display"
        case .display(.previous): return "Previous Display"
        case .display(.above): return "Display Above"
        case .display(.below): return "Display Below"
        case .space(.next): return "Next Space"
        case .space(.previous): return "Previous Space"
        case .space(.above): return "Space Above"
        case .space(.below): return "Space Below"
        }
    }
}
