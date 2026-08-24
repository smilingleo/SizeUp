import AppKit
import Diagnostics

/// Puts a `CGImage` on the general pasteboard as PNG.
///
/// `NSPasteboard` is the native path (the Rust app used the `arboard` crate for
/// the same job). PNG rather than a raw bitmap because it is lossless, the
/// universally supported image type on the pasteboard, and what a screenshot
/// is.
public enum Clipboard {
    /// Copy the image to the general pasteboard as PNG.
    @discardableResult
    public static func copy(_ image: CGImage) -> Bool {
        guard let png = pngData(from: image) else {
            Log.problem("could not encode the capture for the clipboard")
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        return true
    }

    /// PNG bytes for the image, or `nil` if the bitmap rep cannot be created.
    /// Shared with `FileSaver` so the encoding is spelled once.
    public static func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
