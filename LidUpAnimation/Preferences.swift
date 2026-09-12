import Combine
import Foundation
import ServiceManagement

/// User settings backed by `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Master switch for the fold effect.
    @Published var isEnabled: Bool { didSet { save(isEnabled, "isEnabled") } }

    /// The picture anchors where the lid rests, but never above this angle.
    /// Closing past it starts the effect; opening back past it clears it.
    @Published var anchorAngle: Double { didSet { save(anchorAngle, "anchorAngle") } }

    /// Degrees the lid must close from rest before the effect starts, when it
    /// rests below the anchor angle.
    @Published var startDelta: Double { didSet { save(startDelta, "startDelta") } }

    /// Lid angle at which the picture is fully dark.
    @Published var darkAngle: Double { didSet { save(darkAngle, "darkAngle") } }

    /// Distance from the eye to the screen centre, in screen heights.
    /// Smaller values exaggerate the perspective.
    @Published var viewingDistance: Double { didSet { save(viewingDistance, "viewingDistance") } }

    /// Gaussian blur radius at full effect, in points.
    @Published var maxBlurRadius: Double { didSet { save(maxBlurRadius, "maxBlurRadius") } }

    /// Darkening at full effect, 0...1.
    @Published var maxDim: Double { didSet { save(maxDim, "maxDim") } }

    /// Ease the picture back and hand the screen back when the lid holds still.
    @Published var clearsWhenStill: Bool { didSet { save(clearsWhenStill, "clearsWhenStill") } }

    /// Seconds of stillness before the effect clears.
    @Published var stillDelay: Double { didSet { save(stillDelay, "stillDelay") } }

    @Published var showsAngleInMenuBar: Bool { didSet { save(showsAngleInMenuBar, "showsAngleInMenuBar") } }

    @Published var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    /// Mirrors `SMAppService`. Setting it registers or unregisters the app.
    @Published var launchesAtLogin: Bool {
        didSet {
            guard launchesAtLogin != oldValue else { return }
            do {
                if launchesAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchesAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private let defaults = UserDefaults.standard

    private static let factory: [String: Any] = [
        "isEnabled": true,
        "anchorAngle": 100.0,
        "startDelta": 2.0,
        "darkAngle": 25.0,
        "viewingDistance": 2.5,
        "maxBlurRadius": 90.0,
        "maxDim": 1.0,
        "clearsWhenStill": true,
        "stillDelay": 2.0,
        "showsAngleInMenuBar": false,
        "hasCompletedOnboarding": false,
    ]

    private init() {
        defaults.register(defaults: Self.factory)
        isEnabled = defaults.bool(forKey: "isEnabled")
        anchorAngle = defaults.double(forKey: "anchorAngle")
        startDelta = defaults.double(forKey: "startDelta")
        darkAngle = defaults.double(forKey: "darkAngle")
        viewingDistance = defaults.double(forKey: "viewingDistance")
        maxBlurRadius = defaults.double(forKey: "maxBlurRadius")
        maxDim = defaults.double(forKey: "maxDim")
        clearsWhenStill = defaults.bool(forKey: "clearsWhenStill")
        stillDelay = defaults.double(forKey: "stillDelay")
        showsAngleInMenuBar = defaults.bool(forKey: "showsAngleInMenuBar")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func resetTuning() {
        anchorAngle = Self.factory["anchorAngle"] as! Double
        startDelta = Self.factory["startDelta"] as! Double
        darkAngle = Self.factory["darkAngle"] as! Double
        viewingDistance = Self.factory["viewingDistance"] as! Double
        maxBlurRadius = Self.factory["maxBlurRadius"] as! Double
        maxDim = Self.factory["maxDim"] as! Double
        clearsWhenStill = Self.factory["clearsWhenStill"] as! Bool
        stillDelay = Self.factory["stillDelay"] as! Double
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
