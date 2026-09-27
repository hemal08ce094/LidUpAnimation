import XCTest
@testable import LidUpAnimation

final class FoldStyleTests: XCTestCase {
    func testClassicHasNoTint() {
        XCTAssertEqual(FoldStyle.classic.tone.strength, 0)
    }

    func testNonClassicStylesHaveATint() {
        for style in FoldStyle.allCases where style != .classic {
            XCTAssertGreaterThan(style.tone.strength, 0, "\(style) should have a visible tint")
        }
    }

    func testToneComponentsAreValidColour() {
        for style in FoldStyle.allCases {
            let tone = style.tone
            for component in [tone.shadow.x, tone.shadow.y, tone.shadow.z, tone.highlight.x, tone.highlight.y, tone.highlight.z] {
                XCTAssertGreaterThanOrEqual(component, 0)
                XCTAssertLessThanOrEqual(component, 1)
            }
            XCTAssertGreaterThanOrEqual(tone.strength, 0)
            XCTAssertLessThanOrEqual(tone.strength, 1)
        }
    }

    func testEveryCaseHasADistinctTitle() {
        let titles = Set(FoldStyle.allCases.map(\.title))
        XCTAssertEqual(titles.count, FoldStyle.allCases.count)
    }

    func testAppEnumMapsBackToTheSameStyle() {
        XCTAssertEqual(FoldStyleAppEnum.classic.style, .classic)
        XCTAssertEqual(FoldStyleAppEnum.auroraGlass.style, .auroraGlass)
        XCTAssertEqual(FoldStyleAppEnum.inkWash.style, .inkWash)
        XCTAssertEqual(FoldStyleAppEnum.coolDusk.style, .coolDusk)
    }
}
