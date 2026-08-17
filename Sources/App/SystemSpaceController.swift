import Core
import CoreGraphics
import Geometry
import SpaceKit

/// Adapts `SpaceKit`'s service to the seam `Core` declares.
///
/// `Core` cannot see `SpaceKit` — it imports neither Foundation nor any target
/// that does — so this adapter is the join, and it lives in `App` for the same
/// reason every other concrete collaborator does.
struct SystemSpaceController: SpaceControlling {
    private let service = SpaceService()

    var isAvailable: Bool { service.isAvailable }

    /// Finds the display whose Space list contains the window.
    ///
    /// Deliberately keyed on the window's *actual* Space rather than on which
    /// display its frame overlaps. A window can sit on a Space that is not the
    /// one currently shown on that display, and moving it relative to the
    /// visible Space instead of its own would send it somewhere the user did
    /// not ask for.
    ///
    /// `current` is the window's own Space, not the display's active one, so a
    /// repeated "next Space" walks the strip rather than bouncing off whatever
    /// happens to be on screen.
    func layout(containing windowID: UInt32)
        -> (spaces: [SpaceIdentifier], current: SpaceIdentifier, display: String)?
    {
        let occupied = service.spaces(of: windowID)
        guard !occupied.isEmpty else { return nil }

        for layout in service.displaySpaces() {
            // A window assigned to every Space (`Assign To: All Desktops`)
            // reports many; the first that this display actually owns is the
            // one to move relative to.
            guard let here = occupied.first(where: { layout.spaces.contains($0) }) else { continue }
            return (layout.spaces, here, layout.displayIdentifier)
        }
        return nil
    }

    func move(windowID: UInt32, to space: SpaceIdentifier) -> Bool {
        service.move(windowID: windowID, to: space)
    }

    func activate(_ space: SpaceIdentifier, onDisplay display: String) -> Bool {
        service.activate(space, onDisplay: display)
    }
}
