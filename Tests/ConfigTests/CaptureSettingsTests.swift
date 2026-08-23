import Foundation
import Testing
@testable import Config

// `CaptureSettings` is a new field on `Settings` that must not disturb existing
// files. The load-bearing guarantees are: an absent `capture` key decodes to
// "both on", and a round-trip of an explicitly-set value preserves it.

@Test func anAbsentCaptureKeyDefaultsToBothOn() throws {
    let json = """
    {
      "gaps": {"inner": 2, "outer": 4},
      "followsWindowToSpace": false
    }
    """
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.capture.showCursorInRecordings)
    #expect(settings.capture.showClickRipples)
}

@Test func anExplicitCaptureValueIsPreserved() throws {
    let json = """
    {
      "capture": { "showCursorInRecordings": false, "showClickRipples": true }
    }
    """
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(!settings.capture.showCursorInRecordings)
    #expect(settings.capture.showClickRipples)

    // Round-trips exactly: a save that changed only `capture` writes it back.
    let encoded = try JSONEncoder().encode(settings)
    let again = try JSONDecoder().decode(Settings.self, from: encoded)
    #expect(again.capture == settings.capture)
    #expect(!again.capture.showCursorInRecordings)
}

@Test func aSingleToggleDecodesWithTheOtherOn() throws {
    // Partial objects decode: a file that set only one toggle keeps the other
    // at its default rather than trapping on the missing key.
    let json = #"{"capture": {"showCursorInRecordings": false}}"#
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(!settings.capture.showCursorInRecordings)
    #expect(settings.capture.showClickRipples)
}
