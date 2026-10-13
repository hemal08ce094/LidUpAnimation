import Foundation
import StoreKit

/// Asks for an App Store rating after the fifth finished fold, once the folds
/// span at least three different days, and at most once per app version.
/// Called only when a fold plays through and clears, never on launch.
@MainActor
enum ReviewPrompt {
    private static let defaults = UserDefaults.standard
    private static let foldsKey = "review.finishedFolds"
    private static let daysKey = "review.foldDays"
    private static let askedVersionKey = "review.askedVersion"
    private static let requiredFolds = 5
    private static let requiredDays = 3

    static func recordFinishedFold() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard defaults.string(forKey: askedVersionKey) != version else { return }

        let folds = defaults.integer(forKey: foldsKey) + 1
        defaults.set(folds, forKey: foldsKey)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var days = Set(defaults.stringArray(forKey: daysKey) ?? [])
        days.insert(formatter.string(from: Date()))
        defaults.set(Array(days).sorted().suffix(30), forKey: daysKey)

        guard folds >= requiredFolds, days.count >= requiredDays else { return }
        defaults.set(version, forKey: askedVersionKey)
        // Wait for the overlay to fade so the sheet lands on a clear screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            SKStoreReviewController.requestReview()
        }
    }
}
