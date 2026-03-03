/// RequestVerificationTests.swift
///
/// Demonstrates how to use takeRequest() to verify what your code actually sent
/// to the server -- method, path, headers, and body.

import Foundation
import Testing
import MockWebServer

@Suite struct RequestVerificationTests {

    // MARK: - Verify request details

    /// Use takeRequest() to inspect exactly what was sent.
    @Test func verifyAuthorizationHeader() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody(.text("OK")))

        // Simulate an authenticated API call
        let url = server.url(forPath: "/api/me")
        var request = URLRequest(url: url)
        request.setValue("Bearer my-token-123", forHTTPHeaderField: "Authorization")

        _ = try await URLSession.shared.data(for: request)

        let recorded = await server.takeRequest()
        let req = try #require(recorded)
        #expect(req.method == "GET")
        #expect(req.path == "/api/me")

        let authHeader = req.headers.first { $0.0 == "Authorization" }
        #expect(authHeader?.1 == "Bearer my-token-123")
    }

    // MARK: - Verify request ordering

    /// takeRequest() returns requests in FIFO order, so you can verify
    /// that your code makes calls in the expected sequence.
    @Test func verifyCallOrder() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200))
        server.enqueue(MockResponse(statusCode: 200))
        server.enqueue(MockResponse(statusCode: 200))

        let session = URLSession(configuration: .ephemeral)

        // Simulate: login, then fetch profile, then fetch settings
        _ = try await session.data(from: server.url(forPath: "/auth/login"))
        _ = try await session.data(from: server.url(forPath: "/api/profile"))
        _ = try await session.data(from: server.url(forPath: "/api/settings"))

        let r1 = await server.takeRequest()
        let r2 = await server.takeRequest()
        let r3 = await server.takeRequest()

        #expect(r1?.path == "/auth/login")
        #expect(r2?.path == "/api/profile")
        #expect(r3?.path == "/api/settings")
    }

    // MARK: - Async waiting for requests

    /// takeRequest() waits asynchronously if no request has arrived yet.
    /// It returns nil after the timeout expires.
    @Test func takeRequestWithTimeout() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        // No request will arrive, so this should time out
        let result = await server.takeRequest(timeout: .milliseconds(200))
        #expect(result == nil)
    }
}
