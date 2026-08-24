import AppKit
import Config
import SwiftUI

/// A single entry in the fixed size-cycling catalogue.
///
/// The catalogue is fixed rather than free-form on purpose (see the M3 plan,
/// Task 4): a free-form `occupied/columns` editor would let the user build
/// exactly the invalid spans `SpanSetting.resolved` exists to reject, and
/// would ask them to think in a column model they never chose. Anything the
/// catalogue cannot express is still reachable by hand-editing the JSON,
/// which is why `SettingsStore` writes pretty-printed, sorted-key output.
struct CatalogueSpan: Identifiable, Equatable {
    let symbol: String
    let occupied: Int
    let columns: Int
    var id: String { "\(occupied)/\(columns)" }
}

/// The view model behind the Preferences window.
///
/// Deliberately free of validation logic: every `if` about what a valid gap
/// or span is belongs in `Config`, where it is tested (`GapSettings`,
/// `SpanSetting`). This type only shuttles UI state into a `Settings` value
/// and asks `SettingsStore` to persist it. That split is what lets the plan
/// say, honestly, that this file needs no tests.
@MainActor
@Observable
final class PreferencesViewModel {
    /// Canonical order per the plan: ½, ⅓, ⅔, ¼, ¾. Checked entries are
    /// written to `cycle` in this order regardless of the order the user
    /// checked them in, because the router applies the cycle in array
    /// order and the plan requires catalogue order.
    static let catalogue: [CatalogueSpan] = [
        CatalogueSpan(symbol: "½", occupied: 1, columns: 2),
        CatalogueSpan(symbol: "⅓", occupied: 1, columns: 3),
        CatalogueSpan(symbol: "⅔", occupied: 2, columns: 3),
        CatalogueSpan(symbol: "¼", occupied: 1, columns: 4),
        CatalogueSpan(symbol: "¾", occupied: 3, columns: 4),
    ]

    private let store: SettingsStore
    private let onChange: () -> Void

    var innerGap: Double
    var outerGap: Double
    /// The cycle exactly as it will be written, in order.
    ///
    /// One ordered list rather than "a set of checked catalogue boxes, plus
    /// custom spans appended". The split version preserved spans the catalogue
    /// could not express while silently rewriting the ORDER of the ones it could
    /// — so a user who hand-edited the cycle to put two-thirds first lost that on
    /// the next click. Order is load-bearing: the router indexes this array by
    /// cycle step. Keeping one list makes the catalogue and hand-edited entries
    /// obey the same rule, which is also less code.
    private(set) var cycle: [SpanSetting] = []
    /// How many entries were discarded as invalid, so the UI can admit it
    /// rather than quietly dropping them.
    private(set) var droppedInvalidCycleEntries = 0
    var skippedBundleIdentifiers: [String]
    /// Shown inline rather than dropped, per the plan: a settings screen
    /// that fails to persist without saying so is worse than one that
    /// blocks the user.
    var errorMessage: String?

    init(store: SettingsStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        innerGap = 0
        outerGap = 0
        skippedBundleIdentifiers = []
        adopt(store.settings)
    }

    /// Re-reads the settings file and adopts it.
    ///
    /// Called every time the window is shown, because the file can change
    /// underneath us — the user may have hand-edited it since the last showing,
    /// and a view model built from stale values would write those edits away on
    /// the next keystroke.
    func reload() {
        store.load()
        adopt(store.settings)
        // Publish, so the running router matches what this window now displays.
        // Without this, a hand-edit made while the app was running would be shown
        // here but not applied until the user happened to touch a control.
        onChange()
    }

    private(set) var followsWindowToSpace = true

    private func adopt(_ settings: Config.Settings) {
        // `resolved`, never the raw file values. Two reasons, both load-bearing:
        //
        // `Int(_: Double)` traps for anything beyond Int.max, and the gap labels
        // interpolate `Int(innerGap)`. A hand-edited `"inner": 1e19` decodes
        // fine — JSONDecoder only balks around 1e400 — and would then kill the
        // app every single time the Settings window was opened, leaving no way
        // out but to edit the file. The DTO was built to keep configuration away
        // from trapping code, and reading it raw here walked straight back into
        // it.
        //
        // And displaying an unclamped value would be a lie: windows are tiled
        // with the clamped gap, so a stepper reading 5000 would describe
        // something that is not happening, and the next unrelated edit would
        // persist 5000 again.
        followsWindowToSpace = settings.followsWindowToSpace
        let usable = settings.gaps.resolved
        innerGap = usable.inner
        outerGap = usable.outer
        // De-duplicated because `ForEach(id: \.self)` needs unique ids, and a
        // hand-edited file can repeat an entry.
        var seen = Set<String>()
        skippedBundleIdentifiers = settings.skippedBundleIdentifiers.filter { seen.insert($0).inserted }
        // Entries that resolve to nothing are dropped rather than carried: they
        // are never applied, so keeping them would make the UI claim they were.
        // De-duplicated as well as filtered: a hand-edited `[1/2, 1/2]` would
        // otherwise give two identical consecutive cycle steps, so a press would
        // appear to do nothing.
        var seenSpans = Set<String>()
        cycle = settings.cycle.filter {
            $0.resolved != nil && seenSpans.insert("\($0.occupied)/\($0.columns)").inserted
        }
        droppedInvalidCycleEntries = settings.cycle.count - cycle.count
    }

    /// True when the resolved cycle will not actually cycle — either
    /// nothing is checked (falls back to `[.half]`) or only ½ is checked.
    /// Surfaced so the UI can say plainly that the shortcut will not resize
    /// on a repeat press, rather than let the default look broken.
    /// Whether a repeated press will actually resize anything.
    ///
    /// Derived from the resolved cycle, not from which boxes are ticked: an
    /// invalid entry is never applied, so counting it here would hide the note
    /// exactly when the user most needs it.
    var cycleIsEffectivelyHalfOnly: Bool {
        let resolved = Config.Settings(cycle: cycle).resolvedCycle
        return resolved.count <= 1
    }

    /// Cycle steps the catalogue cannot show, e.g. a hand-edited 2/5.
    var customSpans: [SpanSetting] {
        cycle.filter { Self.catalogue.first(matching: $0) == nil }
    }

    /// Built here rather than in the view: string interpolation over an array
    /// inside a `Form` was part of what made the body fail to type-check.
    var customSpansExplanation: String {
        let list = customSpans.map { "\($0.occupied)/\($0.columns)" }.joined(separator: ", ")
        return "Your settings file also contains \(list), which this list cannot show. "
            + "Those are kept and applied in file order."
    }

    var droppedEntriesExplanation: String {
        droppedInvalidCycleEntries == 1
            ? "One entry in your settings file is not a valid size and is ignored."
            : "\(droppedInvalidCycleEntries) entries in your settings file are not valid sizes "
                + "and are ignored."
    }

    func isChecked(_ span: CatalogueSpan) -> Bool {
        cycle.contains { $0.occupied == span.occupied && $0.columns == span.columns }
    }

    /// Appends at the end rather than at the catalogue position, so the cycle
    /// runs in the order the user built it and an existing order is never
    /// reshuffled by an unrelated edit.
    func setChecked(_ span: CatalogueSpan, to checked: Bool) {
        if checked {
            guard !isChecked(span) else { return }
            cycle.append(SpanSetting(occupied: span.occupied, columns: span.columns))
        } else {
            cycle.removeAll { $0.occupied == span.occupied && $0.columns == span.columns }
        }
        save()
    }

    /// An explicit intent method rather than a `didSet`, matching the rest of
    /// this view model. A `didSet` would also fire from `adopt`, so merely
    /// opening the window would write the settings file back — harmless in
    /// value, but a spurious save that can fail and report an error the user did
    /// nothing to cause.
    func setFollowsWindowToSpace(_ follows: Bool) {
        guard follows != followsWindowToSpace else { return }
        followsWindowToSpace = follows
        save()
    }

    func commitGaps(inner: Double, outer: Double) {
        innerGap = inner
        outerGap = outer
        save()
    }

    /// Ignores a bundle identifier already present, per the plan.
    func addSkipped(_ bundleIdentifier: String) {
        guard !skippedBundleIdentifiers.contains(bundleIdentifier) else { return }
        skippedBundleIdentifiers.append(bundleIdentifier)
        save()
    }

    func removeSkipped(_ bundleIdentifier: String) {
        skippedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
        save()
    }

    private func save() {
        do {
            // Mutating, not reconstructing: this editor knows nothing about
            // shortcut overrides, and rebuilding a whole `Settings` here wiped
            // them every time a gap changed.
            try store.update {
                $0.gaps = GapSettings(inner: innerGap, outer: outerGap)
                $0.cycle = cycle
                $0.skippedBundleIdentifiers = skippedBundleIdentifiers
                $0.followsWindowToSpace = followsWindowToSpace
            }
            errorMessage = nil
            // Only rebuild the router when something was actually
            // persisted; a failed save left the on-disk (and in-store)
            // settings unchanged, so there is nothing for the router to
            // pick up.
            onChange()
        } catch {
            errorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}

extension Array where Element == CatalogueSpan {
    /// The catalogue entry describing the same split as `setting`, if any.
    func first(matching setting: SpanSetting) -> CatalogueSpan? {
        first { $0.occupied == setting.occupied && $0.columns == setting.columns }
    }
}

/// A running, regular (Dock-visible) application, for the skip-list "+"
/// picker. Filters and sorting live here rather than in the view because
/// this list only exists to be Identifiable, sorted, and de-duplicated.
struct RunningApplicationEntry: Identifiable, Equatable {
    let id: String
    let name: String

    /// Excludes ClipShot itself and anything already in `excluding`.
    static func current(excluding: [String]) -> [RunningApplicationEntry] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApplicationEntry? in
                guard let bundleIdentifier = app.bundleIdentifier,
                    bundleIdentifier != ownBundleIdentifier,
                    !excluding.contains(bundleIdentifier)
                else { return nil }
                let name = app.localizedName ?? bundleIdentifier
                return RunningApplicationEntry(id: bundleIdentifier, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct PreferencesView: View {
    @Bindable var viewModel: PreferencesViewModel
    @State private var isPickingApplicationToSkip = false

    // Split into computed sections rather than one `body`. Not stylistic: as a
    // single expression this failed to compile with "the compiler is unable to
    // type-check this expression in reasonable time".
    var body: some View {
        Form {
            gapsSection
            spacesSection
            cyclingSection
            skipListSection
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        // `.grouped` is the macOS form idiom: it renders section headers as
        // headers and puts labels in a leading column, instead of the plain
        // centred text a default Form produces here.
        .formStyle(.grouped)
        // A minimum height is required, not cosmetic: with only a width
        // constraint, `NSHostingController` cannot resolve a grouped Form's
        // intrinsic height and the window collapses to its title bar. Observed
        // as a 460x32 window.
        .frame(minWidth: 460, minHeight: 520)
    }

    private var spacesSection: some View {
        Section("Spaces") {
            Toggle(
                "Follow the window to its new Space",
                isOn: Binding(
                    get: { viewModel.followsWindowToSpace },
                    set: { viewModel.setFollowsWindowToSpace($0) }
                )
            )
            Text(
                viewModel.followsWindowToSpace
                    ? "Moving a window to another Space switches to that Space, which is what SizeUp does."
                    : "The window moves but the screen stays put, so it will look as though the "
                        + "window has closed. Switch Spaces yourself to find it."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var gapsSection: some View {
        Section("Gaps") {
            Stepper(
                "Between windows: \(Int(viewModel.innerGap))",
                value: Binding(
                    get: { viewModel.innerGap },
                    set: { viewModel.commitGaps(inner: $0, outer: viewModel.outerGap) }
                ),
                in: 0...100,
                step: 2
            )
            Stepper(
                "Screen edges: \(Int(viewModel.outerGap))",
                value: Binding(
                    get: { viewModel.outerGap },
                    set: { viewModel.commitGaps(inner: viewModel.innerGap, outer: $0) }
                ),
                in: 0...100,
                step: 2
            )
        }
    }

    private var cyclingSection: some View {
        Section("Size cycling") {
            ForEach(PreferencesViewModel.catalogue) { span in
                Toggle(
                    span.symbol,
                    isOn: Binding(
                        get: { viewModel.isChecked(span) },
                        set: { viewModel.setChecked(span, to: $0) }
                    )
                )
            }
            if viewModel.droppedInvalidCycleEntries > 0 {
                Text(viewModel.droppedEntriesExplanation)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !viewModel.customSpans.isEmpty {
                Text(viewModel.customSpansExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if viewModel.cycleIsEffectivelyHalfOnly {
                Text(
                    "Only \u{00BD} is selected, so pressing the shortcut again will not resize "
                        + "the window. This is the default \u{2014} cycling is off until you "
                        + "check another size."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var skipListSection: some View {
        Section("Skip list") {
            if viewModel.skippedBundleIdentifiers.isEmpty {
                Text("No applications are skipped. ClipShot will move windows in every app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // A per-row remove button rather than `List` + `.onDelete`. Two
            // reasons: swipe-to-delete is not a macOS idiom, so `.onDelete`
            // renders no affordance at all and removal would be reachable only
            // by hand-editing the JSON; and a `List` nested in a `Form` fights
            // the form for vertical space and leaves a large blank gap.
            ForEach(viewModel.skippedBundleIdentifiers, id: \.self) { bundleIdentifier in
                HStack {
                    Text(bundleIdentifier)
                    Spacer()
                    Button {
                        viewModel.removeSkipped(bundleIdentifier)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add Application\u{2026}") { isPickingApplicationToSkip = true }
                .popover(isPresented: $isPickingApplicationToSkip) {
                    RunningApplicationPicker(excluding: viewModel.skippedBundleIdentifiers) {
                        viewModel.addSkipped($0)
                        isPickingApplicationToSkip = false
                    }
                }
        }
    }
}

/// The "+" picker: currently-running regular applications, shown by name
/// with the bundle identifier as a subtitle. A plain text field would ask
/// the user to type a bundle identifier from memory, which nobody does.
private struct RunningApplicationPicker: View {
    let excluding: [String]
    let onPick: (String) -> Void

    var body: some View {
        let entries = RunningApplicationEntry.current(excluding: excluding)
        List(entries) { entry in
            Button {
                onPick(entry.id)
            } label: {
                VStack(alignment: .leading) {
                    Text(entry.name)
                    Text(entry.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320, height: 240)
    }
}
