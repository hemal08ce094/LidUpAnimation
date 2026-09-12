import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let preferences = Preferences.shared
    lazy var controller = LidController(preferences: preferences)

    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-check") {
            let directory = arguments.indices.contains(index + 1) ? arguments[index + 1] : "render-check"
            exit(RenderCheck.run(outputDirectory: directory))
        }

        controller.start()

        if !preferences.hasCompletedOnboarding || !ScreenRecordingPermission.isGranted {
            showOnboarding()
        }
        if arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.controller.runPreview()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(preferences: preferences, controller: controller) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Lid Up"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
