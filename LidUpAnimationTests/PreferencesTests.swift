import XCTest
@testable import LidUpAnimation

@MainActor
final class PreferencesTests: XCTestCase {
    func testSettingStyleRoundTripsThroughRawValue() {
        let original = Preferences.shared.foldStyle
        defer { Preferences.shared.foldStyle = original }
        for style in FoldStyle.allCases {
            Preferences.shared.foldStyle = style
            XCTAssertEqual(Preferences.shared.foldStyleID, style.rawValue)
            XCTAssertEqual(Preferences.shared.foldStyle, style)
        }
    }

    func testUnknownStoredValueFallsBackToClassic() {
        let original = Preferences.shared.foldStyleID
        defer { Preferences.shared.foldStyleID = original }
        Preferences.shared.foldStyleID = "not-a-real-style"
        XCTAssertEqual(Preferences.shared.foldStyle, .classic)
    }
}
