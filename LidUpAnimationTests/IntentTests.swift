import XCTest
@testable import LidUpAnimation

final class IntentTests: XCTestCase {

    // "mac" is checked with a whole-word regex since it is not a substring
    // this app's copy uses inside another word (e.g. "macro"); the others
    // are checked as plain substrings, which is stricter and fine here.
    private let forbiddenSubstrings = ["apple", "iphone", "ipad", "apple watch", "siri", "airpods"]

    func testIntentStringsContainNoAppleTrademarks() {
        for text in IntentTextAudit.strings {
            let lower = text.lowercased()
            for word in forbiddenSubstrings {
                XCTAssertFalse(lower.contains(word), "'\(text)' contains the trademarked word '\(word)'")
            }
            XCTAssertFalse(containsWholeWord(lower, "mac"), "'\(text)' contains the trademarked word 'Mac'")
        }
    }

    private func containsWholeWord(_ haystack: String, _ word: String) -> Bool {
        let pattern = "\\b\(word)\\b"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    func testAppShortcutsMetadataExtracts() {
        let shortcuts = LidUpShortcuts.appShortcuts
        XCTAssertEqual(shortcuts.count, 5)
    }

    @MainActor
    func testPreviewFoldIntentWithoutARunningControllerReturnsADialogInsteadOfCrashing() async throws {
        let originalController = LidBridge.shared.controller
        LidBridge.shared.controller = nil
        defer { LidBridge.shared.controller = originalController }

        let wasEnabled = Preferences.shared.isEnabled
        Preferences.shared.isEnabled = true
        defer { Preferences.shared.isEnabled = wasEnabled }

        _ = try await PreviewFoldIntent().perform()
    }

    @MainActor
    func testEnableAndDisableFoldIntentTogglePreferences() async throws {
        let original = Preferences.shared.isEnabled
        defer { Preferences.shared.isEnabled = original }

        _ = try await DisableFoldIntent().perform()
        XCTAssertFalse(Preferences.shared.isEnabled)

        _ = try await EnableFoldIntent().perform()
        XCTAssertTrue(Preferences.shared.isEnabled)
    }

    @MainActor
    func testSetFoldStyleIntentUpdatesPreferences() async throws {
        let original = Preferences.shared.foldStyle
        defer { Preferences.shared.foldStyle = original }

        var intent = SetFoldStyleIntent()
        intent.style = .inkWash
        _ = try await intent.perform()
        XCTAssertEqual(Preferences.shared.foldStyle, .inkWash)
    }

    @MainActor
    func testLidStatusIntentWithoutASensorReportsInsteadOfCrashing() async throws {
        let originalController = LidBridge.shared.controller
        LidBridge.shared.controller = nil
        defer { LidBridge.shared.controller = originalController }

        _ = try await LidStatusIntent().perform()
    }
}
