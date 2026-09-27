import SwiftUI
import Symbols

@main
struct LidUpAnimationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(controller: delegate.controller, preferences: delegate.preferences)
        } label: {
            MenuBarLabel(controller: delegate.controller, preferences: delegate.preferences)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var controller: LidController
    @ObservedObject var preferences: Preferences

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: preferences.isEnabled ? "laptopcomputer" : "laptopcomputer.slash")
                // A small, native micro-interaction — not a full orb, which
                // would be too heavy for an 18pt menu bar glyph — so the icon
                // itself reads as "live" while the fold is actually playing.
                .symbolEffect(.pulse, isActive: controller.phase != .idle || controller.isPreviewing)
            if preferences.showsAngleInMenuBar, controller.isSensorAvailable {
                Text("\(Int(controller.currentAngle.rounded()))°")
                    .monospacedDigit()
            }
        }
    }
}
