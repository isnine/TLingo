import Foundation

public extension URL {
    var redactedLogDescription: String {
        [scheme, host, path].compactMap { $0 }.joined(separator: " ")
    }
}
