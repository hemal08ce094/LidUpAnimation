import Combine
import SwiftUI

/// The menu bar panel.
struct MenuPanelView: View {
    @ObservedObject var controller: LidController
    @ObservedObject var preferences: Preferences

    @State private var isGranted = ScreenRecordingPermission.isGranted
    @State private var showsTuning = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lid Up").font(.headline)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $preferences.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if !isGranted {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Screen Recording is off", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout.weight(.semibold))
                        Text("Needed to draw a live copy of your screen during the fold. Nothing is stored or sent.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Grant…") { ScreenRecordingPermission.request() }
                                .buttonStyle(.borderedProminent)
                            Button("System Settings") { ScreenRecordingPermission.openSystemSettings() }
                            Button("Relaunch") { ScreenRecordingPermission.relaunch() }
                        }
                        .controlSize(.small)
                    }
                    .padding(4)
                }
            } else if !controller.isSensorAvailable {
                Label("No lid angle sensor found on this Mac.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Button {
                controller.runPreview()
            } label: {
                Label(isGranted ? "Preview the fold" : "Preview the fold (wallpaper)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!preferences.isEnabled || controller.isPreviewing || controller.phase != .idle)

            DisclosureGroup("Tuning", isExpanded: $showsTuning) {
                VStack(alignment: .leading, spacing: 10) {
                    slider("Anchor angle", value: $preferences.anchorAngle, in: 60...140, step: 1, unit: "°")
                    HStack {
                        Text("Below this the fold runs; above it the screen is always clear.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Use current") {
                            preferences.anchorAngle = min(max(controller.currentAngle.rounded(), 60), 140)
                        }
                        .controlSize(.small)
                        .disabled(!controller.isSensorAvailable)
                    }
                    slider("Starts after", value: $preferences.startDelta, in: 1...8, step: 0.5, unit: "°")
                    slider("Fully dark at", value: $preferences.darkAngle, in: 10...60, step: 1, unit: "°")
                    slider("Viewing distance", value: $preferences.viewingDistance, in: 1.2...6, step: 0.1, unit: "×")
                    slider("Blur", value: $preferences.maxBlurRadius, in: 0...160, step: 5, unit: "pt")
                    slider("Darkening", value: $preferences.maxDim, in: 0...1, step: 0.05, unit: "")
                    Toggle("Clear when the lid holds still", isOn: $preferences.clearsWhenStill)
                    if preferences.clearsWhenStill {
                        slider("After", value: $preferences.stillDelay, in: 0.5...5, step: 0.5, unit: "s")
                    }
                    Button("Reset tuning") { preferences.resetTuning() }
                        .controlSize(.small)
                }
                .padding(.top, 6)
            }
            .font(.callout)

            Divider()

            Toggle("Show angle in menu bar", isOn: $preferences.showsAngleInMenuBar)
            Toggle("Launch at login", isOn: $preferences.launchesAtLogin)

            Divider()

            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 300)
        .onReceive(poll) { _ in
            isGranted = ScreenRecordingPermission.isGranted
        }
        .onAppear { controller.angleObservers += 1 }
        .onDisappear { controller.angleObservers -= 1 }
    }

    private var status: String {
        guard controller.isSensorAvailable else { return "Sensor unavailable" }
        let angle = String(format: "%.1f°", controller.currentAngle)
        switch controller.phase {
        case .idle: return preferences.isEnabled ? "Lid at \(angle), watching" : "Lid at \(angle), off"
        case .active: return "Lid at \(angle), folding"
        case .clearing: return "Lid at \(angle), clearing"
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: step < 1 ? "%.1f%@" : "%.0f%@", value.wrappedValue, unit))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
        }
    }
}
