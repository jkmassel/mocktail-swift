/// MethodRoutingTests.swift
///
/// Demonstrates method-aware routing for testing REST APIs.
/// Method-specific routes take priority over catch-all routes.

import Foundation
import Testing
import MockWebServer

@Suite struct MethodRoutingTests {

    /// Register different responses for GET and POST on the same path.
    @Test func restfulResource() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        server.route("GET", "/api/users", .json(#"[{"id": 1, "name": "Alice"}]"#))
        server.route("POST", "/api/users", .json(#"{"id": 2, "name": "Bob"}"#, statusCode: 201))
        server.route("DELETE", "/api/users", MockResponse(statusCode: 204))

        let session = URLSession(configuration: .ephemeral)

        // GET returns the list
        let (getData, getResp) = try await session.data(from: server.url(forPath: "/api/users"))
        #expect((getResp as! HTTPURLResponse).statusCode == 200)
        #expect(String(data: getData, encoding: .utf8)!.contains("Alice"))

        // POST returns created
        var postReq = URLRequest(url: server.url(forPath: "/api/users"))
        postReq.httpMethod = "POST"
        postReq.httpBody = Data(#"{"name": "Bob"}"#.utf8)
        let (_, postResp) = try await session.data(for: postReq)
        #expect((postResp as! HTTPURLResponse).statusCode == 201)

        // DELETE returns 204
        var deleteReq = URLRequest(url: server.url(forPath: "/api/users"))
        deleteReq.httpMethod = "DELETE"
        let (_, deleteResp) = try await session.data(for: deleteReq)
        #expect((deleteResp as! HTTPURLResponse).statusCode == 204)
    }

    /// Method-specific routes take priority over catch-all routes on the same path.
    @Test func methodRouteOverridesCatchAll() async throws {
        let server = try await MockWebServer().start()
        defer { server.shutdown() }

        // Catch-all for /data
        server.route("/data", .json(#"{"method": "any"}"#))
        // Override just POST
        server.route("POST", "/data", .json(#"{"method": "post"}"#, statusCode: 201))

        let session = URLSession(configuration: .ephemeral)

        // GET uses the catch-all
        let (getData, _) = try await session.data(from: server.url(forPath: "/data"))
        #expect(String(data: getData, encoding: .utf8) == #"{"method": "any"}"#)

        // POST uses the method-specific route
        var postReq = URLRequest(url: server.url(forPath: "/data"))
        postReq.httpMethod = "POST"
        let (postData, postResp) = try await session.data(for: postReq)
        #expect((postResp as! HTTPURLResponse).statusCode == 201)
        #expect(String(data: postData, encoding: .utf8) == #"{"method": "post"}"#)
    }
}
