#if os(macOS)
    import XCTest

    @MainActor
    final class AppleTranslationStrategyBenchmarkUITests: XCTestCase {
        func testStrategies() throws {
            guard let outputPath = ProcessInfo.processInfo.environment["APPLE_TRANSLATION_BENCHMARK_OUTPUT_DIR"]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_APPLE_TRANSLATION_BENCHMARK_OUTPUT_DIR"]
            else {
                throw XCTSkip("Apple Translation benchmark is opt-in.")
            }
            let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            let app = XCUIApplication()
            app.launchEnvironment["APPLE_TRANSLATION_BENCHMARK_OUTPUT_DIR"] = outputPath
            if let inputPath = ProcessInfo.processInfo.environment["TEST_RUNNER_APPLE_TRANSLATION_BENCHMARK_INPUT_PATH"] {
                app.launchEnvironment["APPLE_TRANSLATION_BENCHMARK_INPUT_PATH"] = inputPath
            }
            app.launch()

            let resultsURL = outputURL.appendingPathComponent("results.json")
            let failureURL = outputURL.appendingPathComponent("failure.txt")
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                let hasResults = FileManager.default.fileExists(atPath: resultsURL.path)
                let hasFailure = FileManager.default.fileExists(atPath: failureURL.path)
                if hasResults || hasFailure {
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }

            if FileManager.default.fileExists(atPath: failureURL.path) {
                try XCTFail(String(contentsOf: failureURL, encoding: .utf8))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: resultsURL.path))
        }
    }
#endif
