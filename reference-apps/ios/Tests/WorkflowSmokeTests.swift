import XCTest

final class WorkflowSmokeTests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor func testGuidedJourneyRequiresHardwareBackedStorageBeforeCapture() {
        let app = XCUIApplication()
        app.launchArguments = ["--reference-test-guided-journey"]
        app.launch()
        XCTAssertEqual(app.tabBars.count, 0)
        XCTAssertTrue(app.buttons["journey.begin"].waitForExistence(timeout: 5))
        app.buttons["journey.begin"].tap()
        XCTAssertTrue(app.staticTexts["journey.storage.unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["journey.begin"].exists)
        XCTAssertTrue(app.buttons["journey.saved.retry"].exists)
        XCTAssertFalse(app.buttons["passport.manual"].exists)
        XCTAssertFalse(app.buttons["journey.continueSelfie"].exists)
        XCTAssertEqual(app.tabBars.count, 0)
    }
    #else
    @MainActor func testGuidedJourneyHasOnePassportConfirmationAndNoTabHandoff() {
        let app = XCUIApplication()
        app.launchArguments = ["--reference-test-guided-journey"]
        app.launch()
        XCTAssertEqual(app.tabBars.count, 0)
        app.buttons["journey.begin"].tap()
        let manual = app.buttons["passport.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))
        manual.tap()
        for (id, value) in [("passport.field.document", "L898902C3"), ("passport.field.birth", "740812"), ("passport.field.expiry", "120415")] {
            app.textFields[id].tap()
            app.textFields[id].typeText(value)
        }
        app.buttons["journey.readChip"].tap()
        #if targetEnvironment(simulator)
        XCTAssertTrue(app.buttons["passport.retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["passport.scan"].exists)
        XCTAssertFalse(app.buttons["journey.continueSelfie"].exists)
        #endif
        XCTAssertEqual(app.tabBars.count, 0)
        app.buttons["journey.cancel"].tap()
        XCTAssertTrue(app.buttons["journey.begin"].waitForExistence(timeout: 3))
    }

    #endif

    @MainActor func testGuidedJourneyExpandedRTLAndExamplesReturnToHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(ar-XB)", "-AppleLocale", "ar_XB", "--reference-test-expanded-rtl-dark", "--reference-test-guided-journey"]
        app.launch()
        XCTAssertTrue(app.buttons["journey.begin"].isHittable || app.buttons["journey.saved.retry"].isHittable)
        XCTAssertTrue(app.buttons["journey.developer"].isHittable)
        XCTAssertFalse(app.buttons["journey.examples"].exists)
        XCTAssertFalse(app.buttons["journey.saved.delete"].exists)
        XCTAssertFalse(app.staticTexts["journey.evidence.idle"].exists)
        app.buttons["journey.developer"].tap()
        reveal(app.buttons["journey.examples"], in: app)
        XCTAssertTrue(app.buttons["journey.examples"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "developer-tools-expanded-rtl-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["journey.examples"].tap()
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        app.buttons["journey.closeExamples"].tap()
        XCTAssertTrue(app.buttons["journey.examples"].waitForExistence(timeout: 3))
        app.buttons["navigation.back"].tap()
        XCTAssertTrue(app.buttons["journey.begin"].isHittable || app.buttons["journey.saved.retry"].isHittable)
        XCTAssertEqual(app.tabBars.count, 0)
    }
    @MainActor func testDefaultLaunchShowsThreeCapabilityTabsWithoutAFirstRunJourney() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["capability.document"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        for capability in ["document", "passport", "biometric", "document"] {
            select(capability, in: app)
            XCTAssertEqual(app.tabBars.buttons.count, 3)
            XCTAssertTrue(app.tabBars.buttons["capability.\(capability)"].isSelected)
            XCTAssertFalse(app.buttons["journey.begin"].exists)
            XCTAssertFalse(app.buttons["journey.closeExamples"].exists)
            XCTAssertFalse(app.navigationBars.buttons["navigation.back"].exists)
            XCTAssertFalse(app.otherElements["document.preview"].exists)
            XCTAssertFalse(app.buttons["document.live.capture"].exists)
            XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        }
    }

    @MainActor func testDocumentIntroOffersExplicitCameraStartWithoutSimulation() {
        let app = XCUIApplication()
        app.launch()
        select("document", in: app)
        XCTAssertTrue(app.staticTexts["document.heading"].exists)
        XCTAssertTrue(app.staticTexts["document.message"].exists)
        XCTAssertTrue(app.staticTexts["document.scope"].exists)
        XCTAssertTrue(app.buttons["document.live.start"].isHittable)
        XCTAssertFalse(app.staticTexts["stub.notice"].exists)
        XCTAssertFalse(app.buttons["action.advance"].exists)
        XCTAssertFalse(app.buttons["action.simulateFailure"].exists)
        XCTAssertFalse(app.navigationBars.buttons["developer.menu"].exists)
        XCTAssertFalse(app.buttons["document.live.capture"].exists)
        XCTAssertFalse(app.buttons["document.live.reset"].exists)
    }

    @MainActor func testDocumentCameraDenialReportsFailureWithoutProducingEvidence() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .camera)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        select("document", in: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertEqual(springboard.alerts.count, 0)
        app.buttons["document.live.start"].tap()
        let permission = springboard.alerts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Camera")).firstMatch
        guard permission.waitForExistence(timeout: 5) else {
            return XCTFail("Camera permission was not requested after explicit start")
        }
        XCTAssertTrue(permission.staticTexts["Use the camera to scan ID cards and passport photo pages, or to take a selfie, when you start capture."].exists)
        let deny = permission.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        guard deny.exists else { return XCTFail("Camera permission has no denial action") }
        deny.tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "document.message", "The camera could not start. Check camera permission and try again.")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["document.live.reset"].exists)
        XCTAssertFalse(app.buttons["document.live.capture"].exists)
        XCTAssertFalse(app.images["document.front.original.image"].exists)
        XCTAssertFalse(app.images["document.back.original.image"].exists)
        XCTAssertFalse(app.staticTexts["stub.notice"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "document-camera-unavailable-no-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["document.live.reset"].tap()
        XCTAssertTrue(app.buttons["document.live.start"].waitForExistence(timeout: 3))
    }

    @MainActor func testExpandedRTLAndDarkPresentationRemainsReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(ar-XB)", "-AppleLocale", "ar_XB",
            "--reference-test-expanded-rtl-dark"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.staticTexts.firstMatch.label.contains("العربية"))
        for capability in ["biometric", "document", "passport"] {
            select(capability, in: app)
            let live = capability == "biometric"
            let passport = capability == "passport"
            let disclosure = app.staticTexts[live ? "comparison.scope" : (passport ? "passport.message" : "document.scope")]
            reveal(disclosure, in: app)
            XCTAssertTrue(disclosure.exists)
            XCTAssertTrue(disclosure.label.contains("العربية"))
            XCTAssertFalse(disclosure.label.contains("demo.disclosure"))
            let start = app.buttons[live ? "passport.reference.open" : (passport ? "passport.manual" : "document.live.start")]
            XCTAssertTrue(start.isHittable)
            XCTAssertGreaterThanOrEqual(start.frame.height, 44)
            XCTAssertLessThanOrEqual(start.frame.maxY, app.tabBars.firstMatch.frame.minY)
            if capability == "document" {
                XCTAssertFalse(app.buttons["document.live.capture"].exists)
                XCTAssertFalse(app.staticTexts["stub.notice"].exists)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "expanded-rtl-dark-document"
                attachment.lifetime = .keepAlways
                add(attachment)
                continue
            }
            start.tap()
            if live { app.buttons["passport.manual"].tap() }
            let cancel = app.buttons[live ? "passport.cancel" : (passport ? "passport.cancel" : "action.cancel")]
            XCTAssertTrue(cancel.isHittable)
            XCTAssertTrue(cancel.label.contains("العربية"))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "expanded-rtl-dark-\(capability)"
            attachment.lifetime = .keepAlways
            add(attachment)
            cancel.tap()
            if live { select("biometric", in: app) }
            XCTAssertTrue(app.buttons[live ? "passport.reference.open" : (passport ? "passport.manual" : "document.live.start")].exists)
        }
    }

    @MainActor func testBackgroundDoesNotStartDocumentCameraOrHideCapabilityTabs() {
        let app = XCUIApplication()
        app.launch()
        select("document", in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["document.live.start"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertFalse(app.buttons["document.live.capture"].exists)
        XCTAssertFalse(app.buttons["action.restore"].exists)
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
    }

    @MainActor func testNativeInstructionContainerAndTabNavigation() {
        let app = XCUIApplication()
        app.launch()
        select("document", in: app)
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists)
        XCTAssertTrue(app.staticTexts["document.heading"].exists)
        XCTAssertTrue(app.staticTexts["document.message"].exists)
        let start = app.buttons["document.live.start"]
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(start.isHittable)
        XCTAssertFalse(scroll.buttons["document.live.start"].exists)
        XCTAssertGreaterThanOrEqual(start.frame.minY, scroll.frame.maxY)
        XCTAssertLessThanOrEqual(start.frame.maxY, app.tabBars.firstMatch.frame.minY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "native-ios-document-instruction"
        attachment.lifetime = .keepAlways
        add(attachment)
        select("passport", in: app)
        XCTAssertTrue(app.buttons["passport.start"].exists)
        XCTAssertFalse(app.buttons["document.live.start"].exists)
        app.buttons["passport.manual"].tap()
        XCTAssertTrue(app.textFields["passport.field.document"].exists)
        app.buttons["passport.cancel"].tap()
        XCTAssertTrue(app.buttons["passport.start"].exists)
        select("document", in: app)
        XCTAssertTrue(app.buttons["document.live.start"].exists)
        XCTAssertFalse(app.buttons["document.live.capture"].exists)
        select("biometric", in: app)
        XCTAssertTrue(app.buttons["passport.reference.open"].exists)
        XCTAssertFalse(app.buttons["document.live.start"].exists)
    }

    @MainActor func testFaceComparisonRequiresPortraitBeforeSelfie() {
        let app = XCUIApplication()
        app.launch()
        select("biometric", in: app)
        XCTAssertTrue(app.buttons["passport.reference.open"].isHittable)
        XCTAssertFalse(app.buttons["capture.live.start"].exists)
        XCTAssertFalse(app.buttons["action.start"].exists)
        XCTAssertFalse(app.staticTexts["stub.notice"].exists)
        XCTAssertFalse(app.staticTexts["capture.accepted.body"].exists)
        app.buttons["passport.reference.open"].tap()
        XCTAssertTrue(app.buttons["passport.start"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["passport.manual"].exists)
        select("biometric", in: app)
        XCTAssertTrue(app.buttons["passport.reference.open"].exists)
        XCTAssertFalse(app.buttons["capture.live.start"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "native-ios-face-reference-prerequisite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testLivePassportManualInputAndCancellationHaveNoSimulationPath() {
        let app = XCUIApplication()
        app.launch()
        select("passport", in: app)
        XCTAssertTrue(app.buttons["passport.start"].isHittable)
        XCTAssertTrue(app.buttons["passport.manual"].exists)
        XCTAssertFalse(app.buttons["passport.trust.import"].exists)
        XCTAssertFalse(app.buttons["action.start"].exists)
        XCTAssertFalse(app.navigationBars.buttons["developer.menu"].exists)
        XCTAssertFalse(app.staticTexts["stub.notice"].exists)
        app.buttons["passport.manual"].tap()
        let document = app.textFields["passport.field.document"]
        let birth = app.textFields["passport.field.birth"]
        let expiry = app.textFields["passport.field.expiry"]
        XCTAssertTrue(document.waitForExistence(timeout: 3))
        XCTAssertTrue(birth.exists)
        XCTAssertTrue(expiry.exists)
        document.tap()
        document.typeText("L898902C3")
        birth.tap()
        birth.typeText("740812")
        expiry.tap()
        expiry.typeText("120415")
        let cancel = app.buttons["passport.cancel"]
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.buttons["passport.start"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["passport.field.document"].exists)
        XCTAssertFalse(app.buttons["passport.use"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "native-ios-live-passport-instruction"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testLivePassportScanCanCancelWithoutProducingEvidence() {
        let app = XCUIApplication()
        app.launch()
        select("passport", in: app)
        let permissions = addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            alert.buttons.firstMatch.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permissions) }
        app.buttons["passport.start"].tap()
        app.tap()
        XCTAssertTrue(app.buttons["passport.cancel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["passport.use"].exists)
        app.buttons["passport.cancel"].tap()
        XCTAssertTrue(app.buttons["passport.start"].waitForExistence(timeout: 3))
    }

    @MainActor func testLivePassportSimulatorRefusesNFCWithoutProducingPortrait() {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launch()
        select("passport", in: app)
        app.buttons["passport.manual"].tap()
        for (identifier, value) in [("document", "L898902C3"), ("birth", "740812"), ("expiry", "120415")] {
            let field = app.textFields["passport.field.\(identifier)"]
            field.tap()
            field.typeText(value)
        }
        app.buttons["passport.confirm"].tap()
        XCTAssertTrue(app.buttons["passport.scan"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["passport.trust.import"].exists)
        app.buttons["passport.scan"].tap()
        XCTAssertTrue(app.buttons["passport.retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["passport.use"].exists)
        XCTAssertFalse(app.images["passport.portrait"].exists)
        XCTAssertTrue(app.staticTexts["passport.message"].label.contains("NFC"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "live-passport-unavailable-nfc"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["passport.retry"].tap()
        XCTAssertTrue(app.buttons["passport.scan"].waitForExistence(timeout: 3))
        app.buttons["passport.cancel"].tap()
        XCTAssertTrue(app.buttons["passport.start"].waitForExistence(timeout: 3))
        #endif
    }

    @MainActor private func openExamples(in app: XCUIApplication) {
        if app.tabBars.buttons["capability.document"].exists { return }
        if app.buttons["journey.developer"].exists { app.buttons["journey.developer"].tap() }
        let examples = app.buttons["journey.examples"]
        if examples.exists { examples.tap() }
    }

    @MainActor private func select(_ capability: String, in app: XCUIApplication) {
        openExamples(in: app)
        let tab = app.tabBars.buttons["capability.\(capability)"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp()
        }
    }
}
