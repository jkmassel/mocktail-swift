/// SocketPolicyTests.swift
///
/// Demonstrates how to test timeout and connection failure scenarios
/// using MockWebServer's socket policies.

import Foundation
import Testing
import MockWebServer

@Suite struct SocketPolicyTests {

    // MARK: - Server never responds (timeout testing)

    /// Use .noResponse to test how your code handles a server that accepts
    /// the connection but never sends a reply.
    @Test func requestTimeout() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.enqueue(MockResponse().withSocketPolicy(.noResponse))

        let url = server.url(forPath: "/slow-endpoint")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1 // 1 second timeout
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: url)
            Issue.record("Expected a timeout error")
        } catch {
            // Your code should handle this as a timeout
            // e.g., show a "server not responding" message
        }
    }

    // MARK: - Server drops connection immediately

    /// Use .disconnectImmediately to test how your code handles
    /// a connection that is accepted then immediately closed.
    @Test func connectionDropped() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.enqueue(MockResponse().withSocketPolicy(.disconnectImmediately))

        let url = server.url(forPath: "/unstable")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)

        var request = URLRequest(url: url)
        request.httpMethod = "POST" // POST avoids URLSession auto-retry

        do {
            _ = try await session.data(for: request)
            Issue.record("Expected a connection error")
        } catch {
            // Your code should handle this as a network error
        }
    }

    // MARK: - Throttled response

    /// Use withThrottle(bytesPerSecond:) to simulate a slow network connection.
    /// The body is sent in chunks at the given rate.
    @Test func throttledResponse() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        let body = String(repeating: "x", count: 500)
        server.enqueue(
            MockResponse(statusCode: 200)
                .withBody(.text(body))
                .withThrottle(bytesPerSecond: 65536)
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: server.url(forPath: "/download"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == body)
    }

    // MARK: - Slow response (body delay)

    /// Use withBodyDelay() to simulate a slow server response.
    @Test func slowResponse() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.enqueue(
            MockResponse(statusCode: 200)
                .withBody(.text("Finally!"))
                .withBodyDelay(.milliseconds(500))
        )

        let url = server.url(forPath: "/slow")
        let start = ContinuousClock().now
        let (data, _) = try await URLSession.shared.data(from: url)
        let elapsed = ContinuousClock().now - start

        #expect(String(data: data, encoding: .utf8) == "Finally!")
        #expect(elapsed >= .milliseconds(400)) // At least ~500ms delay
    }
}
