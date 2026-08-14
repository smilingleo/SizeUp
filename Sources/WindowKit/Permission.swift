@preconcurrency import ApplicationServices

public enum AccessibilityPermission {
    /// Whether this process may drive other applications' windows.
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt with a link to the Accessibility settings pane.
    /// Safe to call repeatedly; macOS shows the dialog only once per launch.
    public static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
