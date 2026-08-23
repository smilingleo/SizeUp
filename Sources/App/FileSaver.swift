import AppKit
import Foundation
import UniformTypeIdentifiers

/// Saves a captured image with an `NSSavePanel`.
///
/// The default file name follows the Rust app's convention, `clipshot-` prefix
/// plus a timestamp (it is a capture, and the name is where a user finds it
/// among other screenshots). PNG only in C1 — the editor's lossless/animated
/// options land with it.
public enum FileSaver {
    /// The capture kind, which selects the default name prefix. `capture` in C1;
    /// `recording` and `scroll` join when their flows do.
    public enum Kind: String {
        case capture
        case recording
        case scroll

        var prefix: String {
            switch self {
            case .capture: return "clipshot-capture"
            case .recording: return "clipshot-recording"
            case .scroll: return "clipshot-scroll"
            }
        }
    }

    /// `clipshot-capture-2026-08-21_14-30-05` (seconds-level, colon-free).
    public static func defaultName(
        kind: Kind,
        date: Date = Date(),
        formatter: DateFormatter = makeFormatter()
    ) -> String {
        "\(kind.prefix)-\(formatter.string(from: date)).png"
    }

    public static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// Shows the save panel for `image` (PNG). Main-actor: `NSSavePanel` is
    /// modal UI and is `@MainActor`-isolated, so the caller (the capture
    /// session, also main-actor) invokes it from the main actor.
    ///
    /// - Returns: The chosen file URL, or `nil` if the user cancelled or the
    ///   PNG could not be encoded.
    @MainActor
    public static func save(
        _ image: CGImage,
        kind: Kind,
        defaultName: String? = nil
    ) -> URL? {
        let name = defaultName ?? FileSaver.defaultName(kind: kind)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.png]

        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        guard let png = Clipboard.pngData(from: image) else {
            NSLog("ClipShot: could not encode the capture for saving")
            return nil
        }
        do {
            try png.write(to: destination, options: .atomic)
            return destination
        } catch {
            NSLog("ClipShot: could not write the capture: \(error.localizedDescription)")
            return nil
        }
    }
}
