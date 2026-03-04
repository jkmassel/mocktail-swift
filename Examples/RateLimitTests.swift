/// RateLimitTests.swift
///
/// Demonstrates how to test rate-limiting scenarios with MockWebServer.
/// These patterns are useful for testing retry logic, backoff strategies,
/// and clients that respect Retry-After headers.

import Foundation
import Testing
import MockWebServer

@Suite struct RateLimitTests {

    // MARK: - Simple 429 response

    /// The simplest rate-limit test: enqueue a 429, verify the status code
    /// and Retry-After header your client receives.
    @Test func simpleRateLimitResponse() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.enqueue(.rateLimited(retryAfter: 30))

        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(from: server.url(forPath: "/api/data"))

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 429)
        #expect(http.value(forHTTPHeaderField: "Retry-After") == "30")
    }

    // MARK: - Rate limit with JSON error body

    /// Use the body parameter to return a JSON error when rate-limited.
    /// This is common with REST APIs that include machine-readable error details.
    @Test func rateLimitWithJSONBody() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        let errorBody = #"{"error": "rate_limited", "retry_after": 60}"#
        server.enqueue(.rateLimited(retryAfter: 60, body: .json(errorBody)))

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: server.url(forPath: "/api/users"))

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 429)
        #expect(http.value(forHTTPHeaderField: "Retry-After") == "60")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(data: data, encoding: .utf8) == errorBody)
    }

    // MARK: - Rate limit then success

    /// Use enqueueRateLimited(retryAfter:then:) to set up a 429 followed
    /// by a success response. Your client code must handle the retry itself
    /// (unlike redirects, URLSession does not retry 429s automatically).
    @Test func rateLimitThenSuccess() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.enqueueRateLimited(
            retryAfter: 1,
            then: .json(#"{"status": "ok"}"#)
        )

        let session = URLSession(configuration: .ephemeral)
        let url = server.url(forPath: "/api/data")

        // First request gets 429
        let (_, r1) = try await session.data(from: url)
        let http1 = try #require(r1 as? HTTPURLResponse)
        #expect(http1.statusCode == 429)
        #expect(http1.value(forHTTPHeaderField: "Retry-After") == "1")

        // Retry gets the success response
        let (data, r2) = try await session.data(from: url)
        let http2 = try #require(r2 as? HTTPURLResponse)
        #expect(http2.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"{"status": "ok"}"#)

        #expect(server.requestCount == 2)
    }

    // MARK: - Multiple rate-limit responses before success

    /// Enqueue several 429s with increasing Retry-After values before success.
    /// Use this pattern to test clients that retry multiple times before
    /// the server allows the request through.
    @Test func multipleRateLimitsBeforeSuccess() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        // Server rate-limits twice before succeeding
        server.enqueue(.rateLimited(retryAfter: 1))
        server.enqueue(.rateLimited(retryAfter: 2))
        server.enqueue(.json(#"{"result": "finally"}"#))

        let session = URLSession(configuration: .ephemeral)
        let url = server.url(forPath: "/api/resource")

        // Attempt 1: rate-limited
        let (_, r1) = try await session.data(from: url)
        let http1 = try #require(r1 as? HTTPURLResponse)
        #expect(http1.statusCode == 429)
        #expect(http1.value(forHTTPHeaderField: "Retry-After") == "1")

        // Attempt 2: still rate-limited, longer wait
        let (_, r2) = try await session.data(from: url)
        let http2 = try #require(r2 as? HTTPURLResponse)
        #expect(http2.statusCode == 429)
        #expect(http2.value(forHTTPHeaderField: "Retry-After") == "2")

        // Attempt 3: success
        let (data, r3) = try await session.data(from: url)
        let http3 = try #require(r3 as? HTTPURLResponse)
        #expect(http3.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"{"result": "finally"}"#)

        #expect(server.requestCount == 3)
    }

    // MARK: - Dynamic rate limiter with closure route

    /// Use a closure route with routeHitCount to build a dynamic rate limiter
    /// that returns 429 for the first N requests, then succeeds.
    @Test func dynamicRateLimiterWithClosureRoute() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.route("/api/limited") { _ in
            let hits = server.routeHitCount(forPath: "/api/limited")
            if hits <= 2 {
                return .rateLimited(retryAfter: 1)
            }
            return .json(#"{"data": "success"}"#)
        }

        let session = URLSession(configuration: .ephemeral)
        let url = server.url(forPath: "/api/limited")

        // First two requests are rate-limited
        let (_, r1) = try await session.data(from: url)
        let http1 = try #require(r1 as? HTTPURLResponse)
        #expect(http1.statusCode == 429)

        let (_, r2) = try await session.data(from: url)
        let http2 = try #require(r2 as? HTTPURLResponse)
        #expect(http2.statusCode == 429)

        // Third request succeeds
        let (data, r3) = try await session.data(from: url)
        let http3 = try #require(r3 as? HTTPURLResponse)
        #expect(http3.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"{"data": "success"}"#)

        #expect(server.routeHitCount(forPath: "/api/limited") == 3)
    }

    // MARK: - Verify retry requests

    /// Use takeRequest() to verify your client retried correctly —
    /// same path, same method, same headers, and same body on each attempt.
    @Test func verifyRetryRequests() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.enqueueRateLimited(retryAfter: 1, then: .json(#"{"ok": true}"#))

        let session = URLSession(configuration: .ephemeral)
        let url = server.url(forPath: "/api/action")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer token-123", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action": "sync"}"#.utf8)

        // First attempt: gets 429
        let (_, r1) = try await session.data(for: request)
        let http1 = try #require(r1 as? HTTPURLResponse)
        #expect(http1.statusCode == 429)

        // Second attempt: same request, gets 200
        let (data, r2) = try await session.data(for: request)
        let http2 = try #require(r2 as? HTTPURLResponse)
        #expect(http2.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"{"ok": true}"#)

        // Verify both requests arrived with the correct details
        #expect(server.requestCount == 2)

        let first = try #require(await server.takeRequest())
        #expect(first.method == "POST")
        #expect(first.path == "/api/action")
        #expect(first.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer token-123" })
        #expect(first.body == Data(#"{"action": "sync"}"#.utf8))

        let second = try #require(await server.takeRequest())
        #expect(second.method == "POST")
        #expect(second.path == "/api/action")
        #expect(second.headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer token-123" })
        #expect(second.body == Data(#"{"action": "sync"}"#.utf8))
    }
}
