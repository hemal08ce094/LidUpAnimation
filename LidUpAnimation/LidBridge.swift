import Foundation

/// The seam between App Intents and the running app.
///
/// Intents run in this process, but `LidController` is owned by
/// `AppDelegate`, not a singleton. `AppDelegate` registers it here once the
/// app has launched, so an intent that arrives before then (or if the
/// controller has no sensor to watch) can still answer sensibly instead of
/// crashing.
@MainActor
final class LidBridge {
    static let shared = LidBridge()
    private init() {}

    weak var controller: LidController?
}
