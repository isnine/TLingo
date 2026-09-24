import XCTest

final class ModelResultOrderUITests: XCTestCase {
    @MainActor
    func testChoosingAndPersistingResultOrder() {
        let app = XCUIApplication()
        app.launchArguments = ["-SNAPSHOT_TAB", "home", "-AppleLanguages", "(en)"]
        app.launch()
        let modelButton = app.buttons["home_model_picker"]
        XCTAssertTrue(modelButton.waitForExistence(timeout: 10))
        modelButton.tap()
        let picker = app.buttons["modelSelection.resultOrder"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let choices = ["First Completed First", "Last Completed First", "Model List Order"]
        let initial = choices.first { picker.label.contains($0) } ?? choices[0]
        for choice in choices {
            picker.tap()
            let option = app.buttons[choice]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(picker.label.contains(choice))
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(modelButton.waitForExistence(timeout: 10))
        modelButton.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.label.contains("Model List Order"))
        picker.tap()
        app.buttons[initial].tap()
        XCTAssertTrue(picker.label.contains(initial))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Model selection sheet result order"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
