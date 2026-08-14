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
    var checkedSpanIDs: Set<CatalogueSpan.ID>
    /// Cycle steps that exist on disk but are not in the catalogue, e.g. a
    /// hand-edited 2/5. Held so `save()` can write them back.
    ///
    /// Without this, checking any box would silently delete them — and the plan
    /// promises hand-editing the JSON as the escape hatch for spans the
    /// catalogue cannot express, so destroying those edits would break the
    /// feature's only stated workaround. Same lost-update hazard the single
    /// window guards against, arriving through the file instead.
    private(set) var customSpans: [SpanSetting] = []
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
        checkedSpanIDs = []
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
    }

    private func adopt(_ settings: Config.Settings) {
        innerGap = settings.gaps.inner
        outerGap = settings.gaps.outer
        skippedBundleIdentifiers = settings.skippedBundleIdentifiers
        checkedSpanIDs = Set(
            settings.cycle.compactMap { Self.catalogue.first(matching: $0)?.id }
        )
        customSpans = settings.cycle.filter { Self.catalogue.first(matching: $0) == nil }
    }

    /// True when the resolved cycle will not actually cycle — either
    /// nothing is checked (falls back to `[.half]`) or only ½ is checked.
    /// Surfaced so the UI can say plainly that the shortcut will not resize
    /// on a repeat press, rather than let the default look broken.
    var cycleIsEffectivelyHalfOnly: Bool {
        guard customSpans.isEmpty else { return false }
        return checkedSpanIDs.isEmpty
            || (checkedSpanIDs.count == 1 && checkedSpanIDs.contains(Self.catalogue[0].id))
    }

    /// Built here rather than in the view: string interpolation over an array
    /// inside a `Form` was part of what made the body fail to type-check.
    var customSpansExplanation: String {
        let list = customSpans.map { "\($0.occupied)/\($0.columns)" }.joined(separator: ", ")
        return "Your settings file also contains \(list), which this list cannot show. "
            + "They are kept, and applied after the sizes above."
    }

    func isChecked(_ span: CatalogueSpan) -> Bool {
        checkedSpanIDs.contains(span.id)
    }

    func setChecked(_ span: CatalogueSpan, to checked: Bool) {
        if checked {
            checkedSpanIDs.insert(span.id)
        } else {
            checkedSpanIDs.remove(span.id)
        }
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
        // Catalogue order first, then anything hand-edited that the catalogue
        // cannot show. Appending rather than interleaving because the router
        // applies the cycle in array order, and there is no way to know where in
        // that order a custom step was meant to sit.
        let cycle = Self.catalogue
            .filter { checkedSpanIDs.contains($0.id) }
            .map { SpanSetting(occupied: $0.occupied, columns: $0.columns) }
            + customSpans
        let newSettings = Config.Settings(
            gaps: GapSettings(inner: innerGap, outer: outerGap),
            cycle: cycle,
            skippedBundleIdentifiers: skippedBundleIdentifiers
        )
        do {
            try store.save(newSettings)
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

    /// Excludes Sizeup2 itself and anything already in `excluding`.
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
                Text("No applications are skipped. Sizeup2 will move windows in every app.")
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
