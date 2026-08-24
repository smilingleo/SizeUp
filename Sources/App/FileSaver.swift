import AppKit
import Foundation
import OverlayUI
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

    /// Ask where a video should go, without touching any files.
    ///
    /// Separate from `saveVideo` because the two callers want different things:
    /// saving a raw recording moves a temporary file into place, while exporting
    /// needs somewhere to *write* and must leave the source alone -- it is still
    /// about to be read from. Conflating them moved the recording out from under
    /// the exporter, so the saved file was the unannotated original.
    @MainActor
    public static func askForVideoDestination(defaultName: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName ?? recordingName()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.mpeg4Movie]
        panel.level = OverlayLevel.aboveOverlay

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Shows the save panel for a finished recording and moves the file there.
    ///
    /// A move rather than a copy: the source is in the temporary directory and
    /// would otherwise be left behind for the system to reap at some point.
    @MainActor
    public static func saveVideo(_ source: URL, defaultName: String? = nil) -> URL? {
        guard let destination = askForVideoDestination(defaultName: defaultName) else {
            return nil
        }
        do {
            // The panel guarantees the user agreed to overwrite, but the move
            // itself fails if something is already there.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            NSLog("ClipShot: could not move the recording into place: \(error)")
            return nil
        }
    }

    /// `clipshot-recording-2026-08-21_14-30-05.mp4`.
    public static func recordingName(date: Date = Date()) -> String {
        "\(Kind.recording.prefix)-\(makeFormatter().string(from: date)).mp4"
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
        // Belt and braces against being buried. The caller takes the overlay
        // down first, but this panel is the only way out of the save flow: if
        // anything is ever left on screen at the overlay window level, an
        // ordinary panel behind it leaves the app looking hung with no way to
        panel.level = OverlayLevel.aboveOverlay

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
