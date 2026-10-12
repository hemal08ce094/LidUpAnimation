import Combine
import Drawably
import SwiftUI
import ThinkingOrbs
import TipKit

/// The menu bar panel.
struct MenuPanelView: View {
    @ObservedObject var controller: LidController
    @ObservedObject var preferences: Preferences
    /// Opens with the tuning section expanded (store-media capture).
    var showsTuningInitially = false

    @State private var isGranted = ScreenRecordingPermission.isGranted
    @State private var showsTuning = false
    @State private var showsStyleGallery = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let styleTip = FoldStyleTip()
    private let paper = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ThinkingOrb(statusOrb, size: .small)
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

            Button {
                showsStyleGallery = true
                styleTip.invalidate(reason: .actionPerformed)
            } label: {
                HStack {
                    Label("Styles", systemImage: preferences.foldStyle.symbolName)
                    Text(preferences.foldStyle.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    DrawablyBadge("new", variant: .scribble)
                }
            }
            .popover(isPresented: $showsStyleGallery, arrowEdge: .trailing) {
                StyleGalleryView(preferences: preferences, controller: controller) {
                    showsStyleGallery = false
                }
            }
            .popoverTip(styleTip, arrowEdge: .trailing)

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

            DrawablyDivider()

            Toggle("Show angle in menu bar", isOn: $preferences.showsAngleInMenuBar)
            Toggle("Launch at login", isOn: $preferences.launchesAtLogin)

            DrawablyDivider()

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
        .onAppear {
            controller.angleObservers += 1
            if showsTuningInitially { showsTuning = true }
        }
        .onDisappear { controller.angleObservers -= 1 }
        .drawably(stroke: .accentColor, fill: .accentColor, paper: paper)
    }

    /// The one status indicator that's always on screen while the app is
    /// running maps to the orb whose meaning is closest to what's actually
    /// happening, instead of a generic spinner.
    private var statusOrb: OrbState {
        guard controller.isSensorAvailable else { return .breathing }
        switch controller.phase {
        case .active, .clearing: return .working
        case .idle:
            // Not `.shaping`: ThinkingOrbs' morph mode indexes out of range
            // when its first frame lands at a negative time (a fresh orb).
            if controller.isPreviewing { return .working }
            return preferences.isEnabled ? .listening : .breathing
        }
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
