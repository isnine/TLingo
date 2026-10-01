import XCTest

final class ModelResultOrderUITests: XCTestCase {
    @MainActor
    func testChoosingAndPersistingResultOrder() {
        let app = XCUIApplication()
        app.launchArguments = ["-SNAPSHOT_TAB", "home", "-AppleLanguages", "(en)"]
        app.launch()
        let modelButton = app.buttons["home_model_picker"]
        XCTAssertTrue(modelButton.waitForExistence(timeout: 10))
        let picker = app.buttons["home_result_order"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let choices = ["First Result First", "Model List Order"]
        let initial = choices.first { picker.value as? String == $0 } ?? choices[0]
        picker.tap()
        XCTAssertFalse(app.buttons["Last Completed First"].waitForExistence(timeout: 1))
        app.buttons[initial].tap()
        for choice in choices {
            picker.tap()
            let option = app.buttons[choice]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertEqual(picker.value as? String, choice)
        }
        modelButton.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["modelSelection.resultOrder"].exists)
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.value as? String, "Model List Order")
        picker.tap()
        app.buttons[initial].tap()
        XCTAssertEqual(picker.value as? String, initial)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Typebar result order toolbar"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
