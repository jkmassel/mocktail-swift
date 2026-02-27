import Foundation

/// An HTTP request captured by ``MockWebServer``.
///
/// Use ``MockWebServer/takeRequest(timeout:)`` to retrieve recorded requests
/// and verify what your code actually sent.
public struct RecordedRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [(String, String)]
    public let body: Data?
}
