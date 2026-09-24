import Foundation

extension URLResponse {
    /// Casts to `HTTPURLResponse`, throwing the caller-provided error if the cast fails.
    func asHTTP<E: Error>(or error: @autoclosure () -> E) throws -> HTTPURLResponse {
        guard let http = self as? HTTPURLResponse else { throw error() }
        return http
    }
}
