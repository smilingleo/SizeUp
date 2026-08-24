import AppKit
import Annotation

/// What the toolbar asks the session to do.
@MainActor
public protocol ToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: ToolbarWindow, didSelect tool: Tool)
    func toolbar(_ toolbar: ToolbarWindow, didPick color: AnnotationColor)
    func toolbar(_ toolbar: ToolbarWindow, didPickStroke width: CGFloat)
    func toolbar(_ toolbar: ToolbarWindow, didPickFontSize size: CGFloat)
    func toolbarDidUndo(_ toolbar: ToolbarWindow)
    func toolbarDidRedo(_ toolbar: ToolbarWindow)
    func toolbarDidCancel(_ toolbar: ToolbarWindow)
    func toolbarDidSave(_ toolbar: ToolbarWindow)
    func toolbarDidConfirm(_ toolbar: ToolbarWindow)
}

/// An NSButton that carries its own closure, so the toolbar can be built as a
/// list rather than a pile of @objc selectors.
final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(symbol: String, fallback: String, tooltip: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        toolTip = tooltip
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        imagePosition = .imageOnly
        target = self
        action = #selector(fire)

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            self.image = image.withSymbolConfiguration(configuration)
        } else {
            // A missing SF Symbol must not leave an invisible button.
            title = fallback
            imagePosition = .noImage
            font = .systemFont(ofSize: 13)
        }
        contentTintColor = .white
    }

    @objc private func fire() { handler?() }

    var isActive: Bool = false {
        didSet {
            layer?.backgroundColor = isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
                : NSColor.clear.cgColor
        }
    }
}

/// A colour swatch, drawn rather than imaged so it needs no assets.
final class SwatchButton: NSButton {
    let color: AnnotationColor
    private var handler: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true } }

    init(color: AnnotationColor, handler: @escaping () -> Void) {
        self.color = color
        super.init(frame: .zero)
        self.handler = handler
        isBordered = false
        title = ""
        target = self
        action = #selector(fire)
        toolTip = color.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dot = bounds.insetBy(dx: 4, dy: 4)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: dot)
        // A ring, so a white swatch is still visible on a light panel and the
        // active one is obvious.
        context.setStrokeColor(isActive ? NSColor.white.cgColor
                                        : NSColor(white: 1, alpha: 0.35).cgColor)
        context.setLineWidth(isActive ? 2 : 1)
        context.strokeEllipse(in: isActive ? bounds.insetBy(dx: 2, dy: 2) : dot)
    }
}

/// A stroke-width button showing a line of that thickness.
final class StrokeButton: NSButton {
    let width: CGFloat
    private var handler: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true } }

    init(width: CGFloat, handler: @escaping () -> Void) {
        self.width = width
        super.init(frame: .zero)
        self.handler = handler
        isBordered = false
        title = ""
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if isActive {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            let path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                              cornerWidth: 5, cornerHeight: 5, transform: nil)
            context.addPath(path)
            context.fillPath()
        }
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: bounds.minX + 7, y: bounds.midY))
        context.addLine(to: CGPoint(x: bounds.maxX - 7, y: bounds.midY))
        context.strokePath()
    }
}

/// The floating editor toolbar: tools on the first row, style on the second.
///
/// A non-activating panel, because the overlay below it has to keep keyboard
/// focus — every tool has a one-key shortcut, and Escape/Return end the
/// capture. A normal window would take first responder on the first click and
/// silently kill all of that.
public final class ToolbarWindow: NSPanel {
    public weak var toolbarDelegate: ToolbarDelegate?

    private var toolButtons: [(Tool, ActionButton)] = []
    private var swatches: [SwatchButton] = []
    private var strokes: [StrokeButton] = []
    private var undoButton: ActionButton?
    private var redoButton: ActionButton?
    private var fontStepper: NSSegmentedControl?
    private var fontLabel: NSTextField?

    private let buttonSize = CGSize(width: 28, height: 24)
    private let swatchSize = CGSize(width: 22, height: 22)
    private let padding: CGFloat = 6
    private let gap: CGFloat = 2
    private let rowGap: CGFloat = 4

    public private(set) var fontSize: CGFloat = AnnotationStyle.defaultFontSize

    public init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 480, height: 74),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        // One above the overlay, so it is never buried by the thing it drives.
        level = OverlayLevel.toolbar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false

        // Pin the dark appearance rather than following the system theme. The
        // toolbar floats over arbitrary screenshot content, and every icon and
        // swatch ring here is drawn white — in light mode the material goes
        // pale and all of it disappears.
        appearance = NSAppearance(named: .darkAqua)

        let root = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        root.appearance = NSAppearance(named: .darkAqua)
        root.material = .hudWindow
        root.blendingMode = .withinWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.autoresizingMask = [.width, .height]
        contentView = root

        build(in: root)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    // MARK: Layout

    private func build(in root: NSView) {
        // Row 1: the tools, then undo/redo, then the actions.
        var x = padding
        let row1Y = padding + swatchSize.height + rowGap

        for tool in Tool.allCases {
            let button = ActionButton(symbol: tool.symbolName, fallback: tool.glyph,
                                      tooltip: "\(tool.label) (\(String(tool.shortcutKey).uppercased()))") {
                [weak self] in
                guard let self else { return }
                toolbarDelegate?.toolbar(self, didSelect: tool)
            }
            button.frame = CGRect(origin: CGPoint(x: x, y: row1Y), size: buttonSize)
            root.addSubview(button)
            toolButtons.append((tool, button))
            x += buttonSize.width + gap
        }

        x += 6
        addDivider(to: root, at: x, y: row1Y, height: buttonSize.height)
        x += 7

        let undo = ActionButton(symbol: "arrow.uturn.backward", fallback: "↩",
                                tooltip: "Undo (⌘Z)") { [weak self] in
            guard let self else { return }
            toolbarDelegate?.toolbarDidUndo(self)
        }
        undo.frame = CGRect(origin: CGPoint(x: x, y: row1Y), size: buttonSize)
        root.addSubview(undo)
        undoButton = undo
        x += buttonSize.width + gap

        let redo = ActionButton(symbol: "arrow.uturn.forward", fallback: "↪",
                               tooltip: "Redo (⇧⌘Z)") { [weak self] in
            guard let self else { return }
            toolbarDelegate?.toolbarDidRedo(self)
        }
        redo.frame = CGRect(origin: CGPoint(x: x, y: row1Y), size: buttonSize)
        root.addSubview(redo)
        redoButton = redo
        x += buttonSize.width + gap

        x += 6
        addDivider(to: root, at: x, y: row1Y, height: buttonSize.height)
        x += 7

        for (symbol, fallback, tip, action) in [
            ("xmark", "✕", "Cancel (Esc)", #selector(noop)),
            ("square.and.arrow.down", "S", "Save to File (⌘S)", #selector(noop)),
            ("checkmark", "✓", "Copy to Clipboard (↩)", #selector(noop)),
        ] {
            _ = action
            let button = ActionButton(symbol: symbol, fallback: fallback, tooltip: tip) {
                [weak self] in
                guard let self else { return }
                switch symbol {
                case "xmark": toolbarDelegate?.toolbarDidCancel(self)
                case "square.and.arrow.down": toolbarDelegate?.toolbarDidSave(self)
                default: toolbarDelegate?.toolbarDidConfirm(self)
                }
            }
            button.frame = CGRect(origin: CGPoint(x: x, y: row1Y), size: buttonSize)
            root.addSubview(button)
            x += buttonSize.width + gap
        }
        let rowWidth = x - gap + padding

        // Row 2: colours, then stroke widths, then the font size.
        var sx = padding
        for color in AnnotationColor.choices {
            let swatch = SwatchButton(color: color) { [weak self] in
                guard let self else { return }
                toolbarDelegate?.toolbar(self, didPick: color)
            }
            swatch.frame = CGRect(origin: CGPoint(x: sx, y: padding), size: swatchSize)
            root.addSubview(swatch)
            swatches.append(swatch)
            sx += swatchSize.width + gap
        }

        sx += 6
        addDivider(to: root, at: sx, y: padding, height: swatchSize.height)
        sx += 7

        for preset in 0..<3 {
            let width = AnnotationStyle.strokeWidth(preset: preset)
            let button = StrokeButton(width: width) { [weak self] in
                guard let self else { return }
                toolbarDelegate?.toolbar(self, didPickStroke: width)
            }
            button.frame = CGRect(origin: CGPoint(x: sx, y: padding),
                                  size: CGSize(width: 32, height: swatchSize.height))
            button.toolTip = ["Thin (1)", "Medium (2)", "Thick (3)"][preset]
            root.addSubview(button)
            strokes.append(button)
            sx += 32 + gap
        }

        sx += 6
        addDivider(to: root, at: sx, y: padding, height: swatchSize.height)
        sx += 7

        let label = NSTextField(labelWithString: "\(Int(fontSize))pt")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.frame = CGRect(x: sx, y: padding + 3, width: 34, height: 16)
        root.addSubview(label)
        fontLabel = label
        sx += 36

        let stepper = NSSegmentedControl(labels: ["−", "+"], trackingMode: .momentary,
                                        target: self, action: #selector(stepFont(_:)))
        stepper.frame = CGRect(x: sx, y: padding, width: 52, height: swatchSize.height)
        root.addSubview(stepper)
        fontStepper = stepper
        sx += 52 + padding

        let width = max(rowWidth, sx)
        let height = padding * 2 + swatchSize.height + rowGap + buttonSize.height
        setContentSize(CGSize(width: width, height: height))
    }

    @objc private func noop() {}

    @objc private func stepFont(_ sender: NSSegmentedControl) {
        let range = AnnotationStyle.fontSizes
        let next = sender.selectedSegment == 0 ? fontSize - 2 : fontSize + 2
        fontSize = min(max(next, range.lowerBound), range.upperBound)
        fontLabel?.stringValue = "\(Int(fontSize))pt"
        toolbarDelegate?.toolbar(self, didPickFontSize: fontSize)
    }

    private func addDivider(to root: NSView, at x: CGFloat, y: CGFloat, height: CGFloat) {
        let line = NSView(frame: CGRect(x: x, y: y + 2, width: 1, height: height - 4))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.25).cgColor
        root.addSubview(line)
    }

    // MARK: State

    /// Mirror the editor into the controls.
    public func sync(with editor: Editor) {
        for (tool, button) in toolButtons { button.isActive = tool == editor.tool }
        for swatch in swatches { swatch.isActive = swatch.color == editor.style.color }
        for stroke in strokes { stroke.isActive = abs(stroke.width - editor.style.width) < 0.01 }
        undoButton?.isEnabled = editor.canUndo
        redoButton?.isEnabled = editor.canRedo
        // The font size only means something for the text tools.
        let textual = editor.tool == .text || editor.tool == .callout
        fontStepper?.isEnabled = textual
        fontLabel?.textColor = textual ? .white : NSColor(white: 1, alpha: 0.4)
        if abs(fontSize - editor.style.fontSize) > 0.01 {
            fontSize = editor.style.fontSize
            fontLabel?.stringValue = "\(Int(fontSize))pt"
        }
    }

    /// Park the toolbar just below the selection, or above it when there is no
    /// room, always fully on screen.
    public func position(near selection: CGRect, on displayFrame: CGRect, viewHeight: CGFloat) {
        let size = frame.size
        // The selection is in flipped view points; convert to screen points.
        let selectionBottom = displayFrame.minY + (viewHeight - selection.maxY)
        let selectionTop = displayFrame.minY + (viewHeight - selection.minY)

        var y = selectionBottom - size.height - 10
        if y < displayFrame.minY + 8 { y = selectionTop + 10 }
        if y + size.height > displayFrame.maxY - 8 {
            y = max(displayFrame.minY + 8, displayFrame.midY - size.height / 2)
        }
        var x = displayFrame.minX + selection.midX - size.width / 2
        x = min(max(x, displayFrame.minX + 8), displayFrame.maxX - size.width - 8)
        setFrameOrigin(CGPoint(x: x.rounded(), y: y.rounded()))
    }
}

// MARK: Tool presentation

extension Tool {
    /// The SF Symbol for this tool, matching the Rust toolbar.
    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pencil: return "pencil.tip"
        case .text: return "textformat"
        case .callout: return "bubble.left"
        case .highlight: return "highlighter"
        case .step: return "1.circle.fill"
        case .blur: return "square.dashed"
        case .crop: return "crop"
        }
    }

    /// Shown if the symbol is unavailable, so a button is never blank.
    var glyph: String {
        switch self {
        case .select: return "↖"
        case .arrow: return "→"
        case .rectangle: return "□"
        case .ellipse: return "○"
        case .pencil: return "✎"
        case .text: return "T"
        case .callout: return "🗨"
        case .highlight: return "▨"
        case .step: return "①"
        case .blur: return "░"
        case .crop: return "⛶"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pencil: return "Pencil"
        case .text: return "Text"
        case .callout: return "Callout"
        case .highlight: return "Highlight"
        case .step: return "Step"
        case .blur: return "Blur"
        case .crop: return "Crop"
        }
    }
}

extension AnnotationColor {
    /// Swatch tooltips, in the order `choices` declares them.
    var name: String {
        let names = ["Pink", "Orange", "Yellow", "Green", "Cyan", "Purple", "Gray", "Black", "White"]
        return AnnotationColor.choices.firstIndex(of: self).map { names[$0] } ?? "Colour"
    }
}
