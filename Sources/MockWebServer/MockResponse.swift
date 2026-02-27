import Foundation

/// Controls how the server handles the TCP connection for a response.
public enum SocketPolicy: Sendable {
    /// Send the response normally. This is the default behavior.
    case keepOpen
    /// Accept connection but never respond (for timeout testing).
    case noResponse
    /// Accept connection then close immediately.
    case disconnectImmediately
}

/// An HTTP response the server will return for a matched request.
///
/// For common cases, use the static factories: ``json(_:statusCode:)``,
/// ``html(_:statusCode:)``, ``text(_:statusCode:)``, or ``redirect(to:type:)``.
public struct MockResponse: Sendable {
    public var statusCode: Int
    public var headers: [(String, String)]
    public var body: Data?
    public var bodyDelay: Duration?
    /// How the server handles the TCP connection. Use `.noResponse` or `.disconnectImmediately`
    /// to simulate network failures.
    public var socketPolicy: SocketPolicy
    /// When set, the response body is sent in chunks at this bytes-per-second rate.
    public var throttleRate: Int?

    public init(
        statusCode: Int = 200,
        headers: [(String, String)] = [],
        body: Data? = nil,
        bodyDelay: Duration? = nil,
        socketPolicy: SocketPolicy = .keepOpen,
        throttleRate: Int? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.bodyDelay = bodyDelay
        self.socketPolicy = socketPolicy
        self.throttleRate = throttleRate
    }

    public func withBody(_ body: String) -> MockResponse {
        var copy = self
        copy.body = Data(body.utf8)
        return copy
    }

    public func withHeader(_ name: String, _ value: String) -> MockResponse {
        var copy = self
        copy.headers.append((name, value))
        return copy
    }

    public func withSocketPolicy(_ policy: SocketPolicy) -> MockResponse {
        var copy = self
        copy.socketPolicy = policy
        return copy
    }

    public func withBodyDelay(_ delay: Duration) -> MockResponse {
        var copy = self
        copy.bodyDelay = delay
        return copy
    }

    /// Returns a copy of this response that throttles body delivery at the given rate.
    ///
    /// The body is sent in chunks, one second's worth of bytes at a time.
    /// Composes with ``withBodyDelay(_:)`` — the delay fires first, then throttled delivery starts.
    public func withThrottle(bytesPerSecond: Int) -> MockResponse {
        var copy = self
        copy.throttleRate = bytesPerSecond
        return copy
    }

    /// Creates a redirect response. The `path` is set as the `Location` header directly,
    /// so it should be an absolute path like `"/api/v2/thing"` or a full URL.
    public static func redirect(to path: String, type: RedirectType = .temporary) -> MockResponse {
        MockResponse(statusCode: type.statusCode, headers: [("Location", path)])
    }

    public static func json(_ body: String, statusCode: Int = 200) -> MockResponse {
        MockResponse(
            statusCode: statusCode,
            headers: [("Content-Type", "application/json")],
            body: Data(body.utf8)
        )
    }

    public static func html(_ body: String, statusCode: Int = 200) -> MockResponse {
        MockResponse(
            statusCode: statusCode,
            headers: [("Content-Type", "text/html; charset=utf-8")],
            body: Data(body.utf8)
        )
    }

    public static func text(_ body: String, statusCode: Int = 200) -> MockResponse {
        MockResponse(
            statusCode: statusCode,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: Data(body.utf8)
        )
    }

    /// Loads a response body from a bundle resource file (typically using `Bundle.module`).
    ///
    /// The `Content-Type` header is inferred from the file extension unless `contentType` is provided.
    /// - Throws: ``MockResponseError/resourceNotFound(_:)`` if the file is missing.
    public static func fromResource(
        _ name: String,
        extension ext: String,
        in bundle: Bundle,
        statusCode: Int = 200,
        contentType: String? = nil
    ) throws -> MockResponse {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw MockResponseError.resourceNotFound("\(name).\(ext)")
        }
        let data = try Data(contentsOf: url)
        let resolvedContentType = contentType ?? Self.contentType(for: ext)
        return MockResponse(
            statusCode: statusCode,
            headers: [("Content-Type", resolvedContentType)],
            body: data
        )
    }

    private static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "json": "application/json"
        case "html", "htm": "text/html; charset=utf-8"
        case "xml": "application/xml"
        case "txt", "text": "text/plain; charset=utf-8"
        case "css": "text/css"
        case "js": "application/javascript"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }
}

/// The type of HTTP redirect, determining the status code and whether the HTTP method is preserved.
public enum RedirectType: Sendable {
    /// 301 Moved Permanently. Clients may change POST to GET.
    case permanent
    /// 302 Found. Clients may change POST to GET.
    case temporary
    /// 307 Temporary Redirect. Preserves the original HTTP method.
    case temporaryPreservingMethod
    /// 308 Permanent Redirect. Preserves the original HTTP method.
    case permanentPreservingMethod

    /// The HTTP status code for this redirect type.
    public var statusCode: Int {
        switch self {
        case .permanent: 301
        case .temporary: 302
        case .temporaryPreservingMethod: 307
        case .permanentPreservingMethod: 308
        }
    }
}

/// Errors thrown when constructing a ``MockResponse``.
public enum MockResponseError: Error {
    /// A bundle resource file could not be found.
    case resourceNotFound(String)
}
