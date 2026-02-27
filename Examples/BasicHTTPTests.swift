/// BasicHTTPTests.swift
///
/// Demonstrates how to use MockWebServer for plain HTTP request/response testing.
/// Copy these patterns into your own test target.

import Foundation
import Testing
import MockWebServer

@Suite struct BasicHTTPTests {

    // MARK: - Simple request/response

    /// The most basic usage: enqueue a response, make a request, check the result.
    @Test func getRequest() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody("Hello, world!"))

        let url = server.url(forPath: "/greeting")
        let (data, response) = try await URLSession.shared.data(from: url)

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "Hello, world!")
    }

    // MARK: - Static content helpers

    /// Use .json() and .html() to create responses with the right Content-Type.
    @Test func staticContentHelpers() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        // .json() sets Content-Type: application/json automatically
        server.enqueue(.json(#"{"status": "ok"}"#))

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: server.url(forPath: "/api/health"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(data: data, encoding: .utf8) == #"{"status": "ok"}"#)
    }

    @Test func htmlResponse() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        // .html() sets Content-Type: text/html; charset=utf-8
        server.enqueue(.html("<h1>Hello</h1>"))

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: server.url(forPath: "/page"))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "<h1>Hello</h1>")
    }

    /// Load response body from a fixture file in your test bundle.
    /// Content-Type is inferred from the file extension.
    ///
    ///     // In your test target, add a "Fixtures/users.json" resource file, then:
    ///     server.enqueue(try .fromResource("users", extension: "json", in: .module))
    ///

    // MARK: - Testing a POST endpoint

    /// Enqueue a response, send a POST with a JSON body, then verify
    /// both the response and the recorded request.
    @Test func postJSON() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.json(#"{"id": 42}"#, statusCode: 201))

        let url = server.url(forPath: "/api/posts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"title": "New Post"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 201)
        #expect(String(data: data, encoding: .utf8) == #"{"id": 42}"#)

        // Verify what the server received
        let recorded = await server.takeRequest()
        let req = try #require(recorded)
        #expect(req.method == "POST")
        #expect(req.path == "/api/posts")
        #expect(req.body == Data(#"{"title": "New Post"}"#.utf8))
    }

    // MARK: - Multiple sequential responses

    /// Enqueue several responses to simulate a multi-step API flow.
    @Test func paginatedAPI() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.json(#"{"items": [1,2,3], "next": "/api/items?page=2"}"#))
        server.enqueue(.json(#"{"items": [4,5,6], "next": null}"#))

        let session = URLSession(configuration: .ephemeral)

        // Fetch page 1
        let (data1, _) = try await session.data(from: server.url(forPath: "/api/items?page=1"))
        #expect(String(data: data1, encoding: .utf8)!.contains("[1,2,3]"))

        // Fetch page 2
        let (data2, _) = try await session.data(from: server.url(forPath: "/api/items?page=2"))
        #expect(String(data: data2, encoding: .utf8)!.contains("[4,5,6]"))

        #expect(server.requestCount == 2)
    }

    // MARK: - Redirect to JSON

    /// Use enqueueRedirect(to:then:) to set up a redirect followed by a JSON response.
    /// URLSession follows redirects automatically, so it hits the server twice.
    @Test func redirectToJSON() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        let json = #"{"users": [{"id": 1, "name": "Alice"}]}"#

        server.enqueueRedirect(to: "/api/v2/users.json", then: .json(json))

        let session = URLSession(configuration: .ephemeral)
        let url = server.url(forPath: "/api/v1/users")
        let (data, response) = try await session.data(from: url)

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == json)

        // Verify the server saw both requests
        #expect(server.requestCount == 2)

        let original = await server.takeRequest()
        #expect(original?.path == "/api/v1/users")

        let redirected = await server.takeRequest()
        #expect(redirected?.path == "/api/v2/users.json")
    }

    // MARK: - Path-based routing

    /// Use route() to register persistent responses for specific paths.
    /// Unlike enqueue(), routes are never consumed and serve every matching request.
    @Test func pathBasedRouting() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/", .html("<h1>Welcome</h1>"))
        server.route("/api/status", .json(#"{"status": "ok", "version": "2.1"}"#))
        server.route("/api/users", .json(#"[{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]"#))

        let session = URLSession(configuration: .ephemeral)

        // Each route serves the same response on every request
        let (homeData, _) = try await session.data(from: server.url(forPath: "/"))
        #expect(String(data: homeData, encoding: .utf8) == "<h1>Welcome</h1>")

        let (statusData, _) = try await session.data(from: server.url(forPath: "/api/status"))
        #expect(String(data: statusData, encoding: .utf8)!.contains("ok"))

        let (usersData, _) = try await session.data(from: server.url(forPath: "/api/users"))
        #expect(String(data: usersData, encoding: .utf8)!.contains("Alice"))

        // Hit the home page again — still works
        let (homeData2, _) = try await session.data(from: server.url(forPath: "/"))
        #expect(String(data: homeData2, encoding: .utf8) == "<h1>Welcome</h1>")
    }

    // MARK: - Route hit counting

    /// Use routeHitCount(forPath:) to verify how many times a path was requested.
    @Test func routeHitCounting() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/api/health", .json(#"{"status": "ok"}"#))

        let session = URLSession(configuration: .ephemeral)
        _ = try await session.data(from: server.url(forPath: "/api/health"))
        _ = try await session.data(from: server.url(forPath: "/api/health"))
        _ = try await session.data(from: server.url(forPath: "/api/health"))

        #expect(server.routeHitCount(forPath: "/api/health") == 3)
        #expect(server.routeHitCount(forPath: "/unknown") == 0)
    }

    // MARK: - Error responses

    /// Test how your code handles various HTTP error codes.
    @Test func errorHandling() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 401).withBody("Unauthorized"))
        server.enqueue(MockResponse(statusCode: 404).withBody("Not Found"))
        server.enqueue(MockResponse(statusCode: 500).withBody("Internal Server Error"))

        let session = URLSession(configuration: .ephemeral)

        let (_, r1) = try await session.data(from: server.url(forPath: "/protected"))
        #expect((r1 as! HTTPURLResponse).statusCode == 401)

        let (_, r2) = try await session.data(from: server.url(forPath: "/missing"))
        #expect((r2 as! HTTPURLResponse).statusCode == 404)

        let (_, r3) = try await session.data(from: server.url(forPath: "/broken"))
        #expect((r3 as! HTTPURLResponse).statusCode == 500)
    }
}
