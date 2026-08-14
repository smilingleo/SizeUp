import Geometry

/// Spacing configuration as stored in the settings file.
///
/// `Gaps` itself is not `Codable` — conforming it retroactively across
/// modules would need `@retroactive` in Swift 6 and would put a
/// serialization format in the geometry layer, which has no business
/// knowing about JSON. This DTO is the seam.
public struct GapSettings: Sendable, Equatable, Codable {
    public var inner: Double
    public var outer: Double

    public init(inner: Double = 0, outer: Double = 0) {
        self.inner = inner
        self.outer = outer
    }

    /// Clamps into `0...100` and maps non-finite values to 0.
    ///
    /// `min`/`max` are not NaN-quieting — `min(max(.nan, 0), 100)` is still
    /// `.nan` — so `isFinite` must be checked explicitly before clamping.
    /// The 100 cap exists because an uncapped inner gap can make
    /// `targetFrame` return a zero-width rect, which `isSafeToApply`
    /// permits (it only rejects negative sizes, not zero).
    public var resolved: Gaps {
        Gaps(inner: Self.clamp(inner), outer: Self.clamp(outer))
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}

/// A step of the size cycle, as stored in the settings file.
///
/// `Span.init` `precondition`-traps on an invalid layout. Because these
/// values come from a user-editable JSON file, a typo (or a hand-edit)
/// must not be able to reach that initializer. `resolved` validates first
/// and returns `nil` instead of constructing a `Span` that could trap.
public struct SpanSetting: Sendable, Equatable, Codable {
    public var occupied: Int
    public var columns: Int

    public init(occupied: Int, columns: Int) {
        self.occupied = occupied
        self.columns = columns
    }

    /// `nil` unless `columns` is in `2...12` and `occupied` is in
    /// `1..<columns`. `occupied < columns`, not `<=`: a span covering every
    /// column is a full screen, not a cycle step, and admitting it would
    /// put a useless step in the user's cycle.
    public var resolved: Span? {
        guard (2...12).contains(columns), (1..<columns).contains(occupied) else { return nil }
        return Span(occupied: occupied, of: columns)
    }
}

/// The user's persisted configuration.
///
/// `Settings()` must reproduce the behaviour `AppDelegate` hardcodes today
/// (`gaps: .zero, spans: [.half], skipList: []`) exactly. Cycling defaults
/// to a single step — effectively off — because the user has thousands of
/// window moves of muscle memory riding on a repeated half-screen shortcut
/// staying a no-op.
public struct Settings: Sendable, Equatable, Codable {
    public var gaps: GapSettings
    public var cycle: [SpanSetting]
    public var skippedBundleIdentifiers: [String]

    public init(
        gaps: GapSettings = GapSettings(),
        cycle: [SpanSetting] = [SpanSetting(occupied: 1, columns: 2)],
        skippedBundleIdentifiers: [String] = []
    ) {
        self.gaps = gaps
        self.cycle = cycle
        self.skippedBundleIdentifiers = skippedBundleIdentifiers
    }

    /// A synthesized `Codable` throws on a missing key, and a settings file
    /// is expected to be hand-editable and incomplete (that is Task 2's
    /// human-readability requirement paying off). Every field is decoded
    /// with `decodeIfPresent` so `{}` decodes to defaults instead of
    /// throwing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        gaps = try container.decodeIfPresent(GapSettings.self, forKey: .gaps) ?? defaults.gaps
        cycle = try container.decodeIfPresent([SpanSetting].self, forKey: .cycle) ?? defaults.cycle
        skippedBundleIdentifiers =
            try container.decodeIfPresent([String].self, forKey: .skippedBundleIdentifiers)
                ?? defaults.skippedBundleIdentifiers
    }

    private enum CodingKeys: String, CodingKey {
        case gaps, cycle, skippedBundleIdentifiers
    }

    /// The resolved cycle, with invalid steps dropped and order preserved.
    ///
    /// Falls back to `[.half]` if every step was invalid, so an all-garbage
    /// cycle list cannot hand `ActionRouter` an empty array. `ActionRouter`
    /// happens to coerce an empty array too, but doing it here means that
    /// coercion stops being load-bearing.
    public var resolvedCycle: [Span] {
        let resolved = cycle.compactMap(\.resolved)
        return resolved.isEmpty ? [.half] : resolved
    }
}
