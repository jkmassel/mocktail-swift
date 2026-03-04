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

    /// Extracts HTTP Basic authentication credentials from the `Authorization` header.
    ///
    /// Returns the username and password as a tuple if present and valid, or `nil` if:
    /// - No `Authorization` header exists
    /// - The header doesn't use the `Basic` scheme
    /// - The Base64 payload is malformed
    ///
    /// ```swift
    /// let request = await server.takeRequest()
    /// if let (username, password) = request?.basicAuthCredentials {
    ///     #expect(username == "admin")
    ///     #expect(password == "secret")
    /// }
    /// ```
    public var basicAuthCredentials: (username: String, password: String)? {
        guard let authHeader = headers.first(where: { $0.0.lowercased() == "authorization" })?.1 else {
            return nil
        }

        guard authHeader.lowercased().hasPrefix("basic ") else {
            return nil
        }

        let base64 = String(authHeader.dropFirst(6))
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        return (username: String(parts[0]), password: String(parts[1]))
    }
}
