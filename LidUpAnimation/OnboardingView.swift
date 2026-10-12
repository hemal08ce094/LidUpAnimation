import Combine
import Drawably
import SwiftUI
import ThinkingOrbs

/// First-run window. Explains the one permission and asks for it.
struct OnboardingView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: LidController
    var finish: () -> Void

    @State private var isGranted = ScreenRecordingPermission.isGranted
    @State private var hasRequested = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let paper = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ThinkingOrb(controller.isSensorAvailable ? .listening : .breathing, size: .large)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lid Up").font(.title.bold())
                    Text("Your desktop folds as the lid closes.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .adaptiveGlass(cornerRadius: 14)

            DrawablyText(Text("As you close the lid, the desktop stays anchored in space, frosts over and slips into black. \(Text("Open it back up").drawably(.underline)) and it returns."))
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    row(ok: controller.isSensorAvailable,
                        title: "Lid angle sensor",
                        detail: controller.isSensorAvailable
                            ? "Found. Read directly from the hinge, no permission needed."
                            : "Not found on this Mac. The effect cannot follow the lid.")
                    Divider()
                    row(ok: isGranted,
                        title: "Screen Recording",
                        detail: isGranted
                            ? "Granted. The live picture of your screen is drawn while the lid moves."
                            : "Needed so the app can draw a live copy of your screen while the lid moves. Nothing is stored or sent anywhere.")
                    if !isGranted {
                        HStack {
                            Button("Grant Screen Recording…") {
                                hasRequested = true
                                ScreenRecordingPermission.request()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Open System Settings") {
                                ScreenRecordingPermission.openSystemSettings()
                            }
                        }
                        if hasRequested {
                            Text("After turning it on, macOS applies the permission to a fresh launch. Use Relaunch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(6)
            }

            Text("That is the only permission. The lid sensor is read through the HID interface, which macOS exposes without a prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Button("Relaunch") { ScreenRecordingPermission.relaunch() }
                    .disabled(!hasRequested && isGranted)
                Spacer()
                Button(isGranted ? "Done" : "Continue without") {
                    preferences.hasCompletedOnboarding = true
                    finish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(poll) { _ in
            isGranted = ScreenRecordingPermission.isGranted
        }
        .drawably(stroke: .accentColor, fill: .accentColor, paper: paper)
    }

    private func row(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
