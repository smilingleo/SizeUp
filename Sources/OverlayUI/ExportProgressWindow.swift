import AppKit

/// A small progress window shown while a recording is being exported.
///
/// Encoding a long recording takes real time, and without any feedback the app
/// looks hung: the editor has closed, no file exists yet, and nothing is
/// happening on screen. Determinate rather than a spinner, because the exporter
/// knows exactly how far along it is.
public final class ExportProgressWindow: NSWindow {
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Exporting…")

    public init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 280, height: 90),
                   styleMask: [.titled], backing: .buffered, defer: false)
        title = "Exporting"
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        level = OverlayLevel.aboveOverlay

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.controlSize = .regular
        bar.frame = CGRect(x: 20, y: 30, width: 240, height: 20)

        label.frame = CGRect(x: 20, y: 56, width: 240, height: 18)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let root = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 90))
        root.addSubview(label)
        root.addSubview(bar)
        contentView = root
    }

    public override var canBecomeKey: Bool { false }

    public func present() {
        center()
        orderFront(nil)
    }

    public func update(_ fraction: Double) {
        bar.doubleValue = min(max(fraction, 0), 1)
        label.stringValue = "Exporting… \(Int(fraction * 100))%"
    }

    public func dismiss() {
        orderOut(nil)
    }
}
