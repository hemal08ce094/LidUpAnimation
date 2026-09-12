import AppKit
import CoreGraphics

/// The one permission the app needs: Screen Recording, so ScreenCaptureKit can
/// hand us a live copy of the built-in display to warp while the lid moves.
/// The lid angle sensor itself needs no permission.
enum ScreenRecordingPermission {

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time. Later calls return the current
    /// state without prompting; the user then has to use System Settings.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// macOS applies a fresh Screen Recording grant to a new process only.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
