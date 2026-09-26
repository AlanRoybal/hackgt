import XCTest

/// End-to-end against the deployed dev backend with the peer bot as the friend.
/// Run through `tools/e2e/ios-e2e.sh`, which starts the bot and passes E2E_RUN.
@MainActor
final class E2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var run: String { ProcessInfo.processInfo.environment["E2E_RUN"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(run.isEmpty, "E2E_RUN not set; run tools/e2e/ios-e2e.sh")
        app = XCUIApplication()
        app.launch()
    }

    func testOnboardFriendMessageCallAndPhoto() throws {
        // Welcome cards → sign-in screen.
        for _ in 0..<4 where !app.textFields["test username"].exists {
            let next = app.buttons["Get started"].exists ? app.buttons["Get started"] : app.buttons["Continue"]
            if next.waitForExistence(timeout: 5) { next.tap() }
        }
        let user = app.textFields["test username"]
        XCTAssert(user.waitForExistence(timeout: 10), "developer sign-in field")
        user.tap()
        user.typeText("e2e_\(run)")
        app.buttons["Go"].tap()

        // Terms → handle.
        XCTAssert(app.buttons["I agree"].waitForExistence(timeout: 20), "Terms screen")
        let handle = app.textFields["yourname"]
        XCTAssert(tapUntil(app.buttons["I agree"], shows: handle), "handle screen")
        handle.tap()
        handle.typeText("e2e_\(run)")
        let name = app.textFields["How friends see you"]
        name.tap()
        name.typeText("E2E User")
        XCTAssert(app.staticTexts["@e2e_\(run) is available"].waitForExistence(timeout: 10), "handle availability check")
        app.buttons["Continue"].tap()

        // Phone (skip) → permission primers (Not now) → add your people (Done).
        if app.buttons["Skip for now"].waitForExistence(timeout: 15) { app.buttons["Skip for now"].tap() }
        while app.buttons["Not now"].waitForExistence(timeout: 4) { app.buttons["Not now"].tap() }
        if app.buttons["Done"].waitForExistence(timeout: 10) { app.buttons["Done"].tap() }

        // The bot finds the handle and sends a friend request.
        let request = app.buttons["Test Bot wants to connect"]
        XCTAssert(request.waitForExistence(timeout: 90), "friend request from the bot")
        request.tap()
        let accept = app.buttons["Accept"].firstMatch
        XCTAssert(accept.waitForExistence(timeout: 10))
        accept.tap()
        if app.buttons["Done"].waitForExistence(timeout: 5) { app.buttons["Done"].tap() }
        XCTAssert(app.staticTexts["Test Bot"].firstMatch.waitForExistence(timeout: 20), "bot in Friends")

        // The bot's message arrives.
        app.tabBars.buttons["Messages"].tap()
        XCTAssert(app.staticTexts["Hello from the bot"].waitForExistence(timeout: 30), "message from the bot")
        app.tabBars.buttons["Friends"].tap()

        // The bot taps Call now → in-app banner → Accept → call.
        let banner = app.otherElements["Nudge from Test Bot"]
        XCTAssert(banner.waitForExistence(timeout: 60), "in-app nudge banner")
        banner.buttons["Accept"].tap()
        // Onboarding primers were skipped, so joining asks for the camera now (simctl can't pre-grant it).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let miniWindow = app.otherElements["Your camera"]
        for _ in 0..<6 {
            if miniWindow.exists, !springboard.alerts.firstMatch.exists { break }
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK', 'Allow While Using App'}")).firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        XCTAssert(miniWindow.waitForExistence(timeout: 40), "in-call screen")

        // The bot shares a photo → my mini window swaps to it.
        let botPhoto = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'from Test Bot'")).firstMatch
        XCTAssert(botPhoto.waitForExistence(timeout: 45), "bot's photo in my mini window")
        attach("call-with-bot-photo")

        // Controls fade after 4 s idle; a tap brings them back.
        if !app.buttons["End call"].isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap() }
        XCTAssert(app.buttons["End call"].waitForExistence(timeout: 5), "call controls")
        app.buttons["End call"].tap()
        XCTAssert(app.staticTexts["You talked with Test Bot"].waitForExistence(timeout: 20), "summary screen")
        attach("summary")
    }

    /// Taps (retrying while a transition settles) until `target` appears. Logs retries so real failures stay visible.
    private func tapUntil(_ button: XCUIElement, shows target: XCUIElement, attempts: Int = 3) -> Bool {
        for attempt in 1...attempts {
            if button.waitForExistence(timeout: 5), button.isHittable { button.tap() }
            if target.waitForExistence(timeout: 10) { return true }
            print("E2E: '\(button.label)' attempt \(attempt) did not advance")
        }
        return false
    }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
