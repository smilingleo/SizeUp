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

    /// Both halves are `SpaceKit`'s: the query, and the pure rule for choosing a
    /// display, which is tested there rather than sitting untested here.
    func layout(containing windowID: UInt32)
        -> (spaces: [SpaceIdentifier], current: SpaceIdentifier, display: String)?
    {
        SpaceService.locate(
            windowOn: service.spaces(of: windowID),
            in: service.displaySpaces()
        )
    }

    func move(windowID: UInt32, to space: SpaceIdentifier) -> Bool {
        service.move(windowID: windowID, to: space)
    }

    func activate(_ space: SpaceIdentifier, onDisplay display: String) -> Bool {
        service.activate(space, onDisplay: display)
    }
}
