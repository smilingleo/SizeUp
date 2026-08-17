import Testing
import Foundation
import CoreGraphics
@testable import Config
@testable import Geometry

/// `AppDelegate` hardcodes `gaps: .zero, spans: [.half], skipList: []` today,
/// and the user has 13,318 window moves of muscle memory riding on that
/// behaviour. `Settings()` must reproduce it exactly, or introducing this
/// type would itself be the regression.
@Test func defaultSettingsReproduceTodaysHardcodedBehaviour() {
    let settings = Settings()
    #expect(settings.gaps.resolved == Gaps.zero)
    #expect(settings.resolvedCycle == [.half])
    #expect(settings.skippedBundleIdentifiers == [])
}

/// SizeUp follows a moved window to its destination Space, and the author
/// has 13,318 window moves of muscle memory riding on that behaviour, so
/// this must default to on rather than off.
@Test func followsWindowToSpaceDefaultsToTrue() {
    #expect(Settings().followsWindowToSpace)
}

@Test func decodingToleratesAMissingFollowsWindowToSpaceField() throws {
    let data = Data("{}".utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.followsWindowToSpace)
}

@Test func aSpanCoveringEveryColumnIsRejected() {
    // occupied == columns is a full screen, not a cycle step; admitting it
    // would put a useless step in the user's cycle.
    #expect(SpanSetting(occupied: 2, columns: 2).resolved == nil)
}

@Test func aZeroColumnSpanIsRejectedRatherThanTrapping() {
    // `Span.init` calls `precondition(columns > 0, ...)` and would crash the
    // process on this input. Settings come from user-editable JSON, so a
    // typo must not be able to reach that initializer; validation happens
    // here, before construction.
    #expect(SpanSetting(occupied: 1, columns: 0).resolved == nil)
}

@Test func oversizedGapsAreClampedNotHonoured() {
    // Measured: an inner gap of 500 produces a zero-width window on a small
    // display (`targetFrame(.half(.left))` collapses to width 0). Clamping
    // at the configuration boundary is what keeps that unreachable.
    let resolved = GapSettings(inner: 500, outer: 500).resolved
    #expect(resolved == Gaps(inner: 100, outer: 100))
}

@Test func negativeGapsClampToZero() {
    let resolved = GapSettings(inner: -5, outer: -100).resolved
    #expect(resolved == Gaps(inner: 0, outer: 0))
}

@Test func nonFiniteGapsClampToZero() {
    // `min`/`max` are not NaN-quieting: `min(max(.nan, 0), 100)` is `.nan`.
    // M2 already learned this the hard way; the clamp here must check
    // `isFinite` explicitly rather than trust min/max alone.
    let resolved = GapSettings(inner: .nan, outer: .infinity).resolved
    #expect(resolved == Gaps(inner: 0, outer: 0))
}

@Test func anAllInvalidCycleFallsBackToHalves() {
    let settings = Settings(cycle: [
        SpanSetting(occupied: 1, columns: 0),
        SpanSetting(occupied: 2, columns: 2),
        SpanSetting(occupied: -1, columns: 3),
    ])
    #expect(settings.resolvedCycle == [.half])
}

@Test func aPartiallyInvalidCycleKeepsTheValidSteps() {
    let settings = Settings(cycle: [
        SpanSetting(occupied: 1, columns: 2),
        SpanSetting(occupied: 5, columns: 3),
        SpanSetting(occupied: 1, columns: 3),
    ])
    // Order matters: this asserts the array, not a set.
    #expect(settings.resolvedCycle == [Span(occupied: 1, of: 2), Span(occupied: 1, of: 3)])
}

@Test func settingsRoundTripThroughJSON() throws {
    let original = Settings(
        gaps: GapSettings(inner: 8, outer: 12),
        cycle: [SpanSetting(occupied: 1, columns: 2), SpanSetting(occupied: 1, columns: 3)],
        skippedBundleIdentifiers: ["com.example.app"]
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded == original)
}

@Test func decodingToleratesMissingFields() throws {
    // A synthesized Codable throws on missing keys, so this forces a
    // hand-written `init(from:)` that uses `decodeIfPresent` per field.
    let data = Data("{}".utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded == Settings())
}
