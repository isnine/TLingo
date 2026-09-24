#if DEBUG && os(macOS)
    import Foundation
    import ShareCore
    import SwiftUI

    struct AppleTranslationStrategyBenchmarkView: View {
        var body: some View {
            if #available(macOS 26.4, *) {
                AppleTranslationStrategyBenchmarkContent()
            }
        }
    }

    @available(macOS 26.4, *)
    private struct AppleTranslationStrategyBenchmarkContent: View {
        @State private var hasStarted = false
        @State private var measurements: [Measurement] = []
        @State private var failures: [Failure] = []

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .task {
                    guard outputDirectory != nil, !hasStarted else { return }
                    hasStarted = true
                    await run()
                }
        }

        @MainActor
        private func run() async {
            guard let outputDirectory else { return }
            for route in routes {
                for input in inputs {
                    let startedAt = ContinuousClock.now
                    do {
                        let result = try await translate(input, route: route)
                        try measurements.append(
                            Measurement(
                                strategy: route.rawValue,
                                run: 1,
                                input: input,
                                durationMilliseconds: startedAt.duration(to: .now).milliseconds,
                                output: result.response.get()
                            )
                        )
                    } catch {
                        failures.append(
                            Failure(
                                strategy: route.rawValue,
                                run: 1,
                                input: input,
                                error: error.localizedDescription
                            )
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(route.cadenceMilliseconds))
                }
            }
            try? writeResults(to: outputDirectory)
        }

        private var routes: [Route] {
            guard let rawValue = ProcessInfo.processInfo.environment["APPLE_TRANSLATION_BENCHMARK_ROUTE"],
                  let route = Route(rawValue: rawValue)
            else {
                return Route.allCases
            }
            return [route]
        }

        private var outputDirectory: URL? {
            ProcessInfo.processInfo.environment["APPLE_TRANSLATION_BENCHMARK_OUTPUT_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        private var inputs: [String] {
            if let path = ProcessInfo.processInfo.environment["APPLE_TRANSLATION_BENCHMARK_INPUT_PATH"] {
                let lines = (try? String(contentsOfFile: path, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline)
                    .map(String.init) ?? []
                if !lines.isEmpty {
                    return lines
                }
            }
            if let input = ProcessInfo.processInfo.environment["APPLE_TRANSLATION_BENCHMARK_INPUT"] {
                return [input]
            }
            return Self.defaultInputs
        }

        private func translate(_ input: String, route: Route) async throws -> ModelExecutionResult {
            switch route {
            case .appleTranslator:
                return try await AppleTranslationService.shared.translateSentencesWithInstalledLanguages(
                    text: input,
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans")
                )
            case .appleTranslationRealtime:
                return try await AppleTranslationService.shared.translateRealtimeSentencesWithInstalledLanguages(
                    text: input,
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans")
                )
            }
        }

        private func writeResults(to outputDirectory: URL) throws {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try JSONEncoder.pretty.encode(measurements)
                .write(to: outputDirectory.appendingPathComponent("results.json"))
            try JSONEncoder.pretty.encode(failures)
                .write(to: outputDirectory.appendingPathComponent("failures.json"))
            try measurements.map { "\($0.strategy)\t\($0.run)\t\($0.durationMilliseconds)" }
                .joined(separator: "\n")
                .appending("\n")
                .write(
                    to: outputDirectory.appendingPathComponent("timings.tsv"),
                    atomically: true,
                    encoding: .utf8
                )
            try inputs.joined(separator: "\n").write(
                to: outputDirectory.appendingPathComponent("input.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        private struct Measurement: Codable {
            let strategy: String
            let run: Int
            let input: String
            let durationMilliseconds: Int
            let output: String
        }

        private struct Failure: Codable {
            let strategy: String
            let run: Int?
            let input: String?
            let error: String
        }

        private enum Route: String, CaseIterable {
            case appleTranslator
            case appleTranslationRealtime

            var cadenceMilliseconds: Int {
                switch self {
                case .appleTranslator:
                    return 500
                case .appleTranslationRealtime:
                    return 350
                }
            }
        }

        private static let defaultInputs = [
            "That works for me.",
            "Let's table this for now.",
            "The rollout is on track.",
            "Please keep me posted.",
            "We need a fallback.",
            "The build broke after the update.",
            "Can you take a look?",
            "I'm running five minutes late.",
            "The charge was declined.",
            "The issue only happens intermittently.",
            "The meeting was pushed back.",
            "Ship it once the tests pass.",
        ]
    }

    private extension Duration {
        var milliseconds: Int {
            Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
        }
    }

    private extension JSONEncoder {
        static var pretty: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return encoder
        }
    }
#endif
