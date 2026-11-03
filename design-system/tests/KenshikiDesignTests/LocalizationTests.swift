import Foundation
import XCTest
@testable import KenshikiDesign

final class LocalizationTests: XCTestCase {
    func testPackagedDefaultResolvesEveryMessage() {
        for message in KenshikiCopy.allCases {
            let value = message.localized()
            XCTAssertFalse(value.isEmpty, message.rawValue)
            XCTAssertNotEqual(value, message.rawValue)
            XCTAssertEqual(KenshikiCopy.text(message.rawValue), value)
        }
        XCTAssertNotEqual(KenshikiCopy.resourceBundle.bundleURL, Bundle.main.bundleURL)
    }

    func testExplicitBundleOverrideUsesSelectedLocale() throws {
        let package = KenshikiCopy.resourceBundle
        let englishPath = try XCTUnwrap(package.path(forResource: "en", ofType: "lproj"))
        let expandedPath = try XCTUnwrap(package.path(forResource: "en-xa", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: englishPath))
        let expanded = try XCTUnwrap(Bundle(path: expandedPath))
        for message in KenshikiCopy.allCases {
            let ordinary = message.localized(bundle: english)
            let pseudo = message.localized(bundle: expanded)
            XCTAssertNotEqual(ordinary, message.rawValue)
            XCTAssertTrue(pseudo.hasPrefix("["), message.rawValue)
            XCTAssertNotEqual(ordinary, pseudo)
            XCTAssertEqual(KenshikiCopy.text(message.rawValue, bundle: expanded), pseudo)
        }
    }

    func testPackagedEnglishFallbackMetadata() throws {
        let package = KenshikiCopy.resourceBundle
        XCTAssertEqual(package.developmentLocalization, "en")
        XCTAssertTrue(package.localizations.contains("en"))
        XCTAssertNil(package.path(forResource: "zz-ZZ", ofType: "lproj"))
        let candidates = Bundle.preferredLocalizations(from: package.localizations, forPreferences: ["zz-ZZ", "en"])
        XCTAssertEqual(candidates, ["en"])
        let englishPath = try XCTUnwrap(package.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: englishPath))
        XCTAssertEqual(KenshikiCopy.appTitle.localized(bundle: english), "Kenshiki SDK Reference")
        XCTAssertEqual(english.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"), KenshikiCopy.appTitle.localized(bundle: english))
    }
}
