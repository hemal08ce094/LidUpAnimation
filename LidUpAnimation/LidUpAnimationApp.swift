import SwiftUI

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
            if preferences.showsAngleInMenuBar, controller.isSensorAvailable {
                Text("\(Int(controller.currentAngle.rounded()))°")
                    .monospacedDigit()
            }
        }
    }
}
