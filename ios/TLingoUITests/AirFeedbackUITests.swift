#if os(iOS)
    import XCTest

    @MainActor
    final class AirFeedbackUITests: XCTestCase {
        func testValidationCancelAndFreshDraftKeepEmailSupportAvailable() {
            let app = launchSettings()
            let emailSupport = app.buttons["settings_email_support_row"]
            reveal(emailSupport, in: app)
            XCTAssertTrue(emailSupport.isEnabled)
            // Deliberately never open the mail composer or tap Send.

            openFeedback(in: app)
            let message = app.descendants(matching: .any)["feedback_message"].firstMatch
            let send = app.buttons["feedback_send"]
            assertEmpty(message)
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            XCTAssertFalse(send.isEnabled)

            message.tap()
            message.typeText("   \n   ")
            XCTAssertFalse(send.isEnabled, "Whitespace alone must not enable Send.")
            message.typeText("The feedback form is easy to find.")
            XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5))

            app.buttons["feedback_cancel"].tap()
            XCTAssertTrue(message.waitForNonExistence(timeout: 5))
            reveal(emailSupport, in: app)
            XCTAssertTrue(emailSupport.isEnabled)

            openFeedback(in: app)
            assertEmpty(message)
            XCTAssertFalse(send.isEnabled, "Cancelling must discard the previous draft.")
            app.buttons["feedback_cancel"].tap()
            XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        }

        func testMessageIsCappedAtFourThousandWithoutSubmitting() {
            let app = launchSettings()
            openFeedback(in: app)
            let message = app.descendants(matching: .any)["feedback_message"].firstMatch
            let send = app.buttons["feedback_send"]
            message.tap()
            message.typeText(String(repeating: "a", count: 4000))
            XCTAssertEqual((message.value as? String)?.utf16.count, 4000)
            XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5))

            message.typeText("b")
            // The form truncates on change; ASCII makes the UTF-16 boundary unambiguous.
            let capped = NSPredicate { _, _ in
                (message.value as? String)?.utf16.count == 4000
            }
            let expectation = XCTNSPredicateExpectation(predicate: capped, object: message)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
            XCTAssertFalse((message.value as? String ?? "").contains("b"))
            XCTAssertTrue(send.isEnabled)
            app.buttons["feedback_cancel"].tap()
            XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        }

        private func launchSettings() -> XCUIApplication {
            continueAfterFailure = false
            let app = XCUIApplication()
            app.launchArguments = ["-SNAPSHOT_TAB", "home", "-AppleLanguages", "(en)"]
            app.launch()
            let settings = app.buttons["tab_settings"]
            if settings.waitForExistence(timeout: 10) {
                settings.tap()
            } else {
                // Regular-width iPad uses the existing sidebar rather than the Home button.
                let sidebarSettings = app.staticTexts["Settings"].firstMatch
                XCTAssertTrue(sidebarSettings.waitForExistence(timeout: 5))
                sidebarSettings.tap()
            }
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            return app
        }

        private func openFeedback(in app: XCUIApplication) {
            let feedback = app.buttons["settings_feedback_row"]
            reveal(feedback, in: app)
            feedback.tap()
            XCTAssertTrue(app.descendants(matching: .any)["feedback_message"].firstMatch
                .waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["feedback_cancel"].exists)
        }

        private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
            for _ in 0 ..< 8 {
                if element.isHittable { break }
                app.swipeUp()
            }
            // A preceding check of the adjacent Help row may have scrolled past this one.
            if !element.isHittable {
                for _ in 0 ..< 8 {
                    if element.isHittable { break }
                    app.swipeDown()
                }
            }
            XCTAssertTrue(element.isHittable)
        }

        private func assertEmpty(_ message: XCUIElement) {
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            let value = message.value as? String ?? ""
            // UIKit may expose an empty text field's placeholder as its value.
            XCTAssertTrue(value.isEmpty || value == message.placeholderValue)
        }
    }
#endif
