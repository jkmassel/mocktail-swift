/// ClosureRouteTests.swift
///
/// Demonstrates how to use closure-based routes for dynamic request handling.
/// The closure receives the full RecordedRequest and can return a response
/// based on any combination of method, path, headers, or body.

import Foundation
import Testing
import MockWebServer

@Suite struct ClosureRouteTests {

    /// Use a closure route to return dynamic responses based on the request.
    @Test func dynamicRouting() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/api/users") { request in
            .json(#"{"path": "\#(request.path)"}"#)
        }

        server.enqueue(.html("<h1>Fallback</h1>"))

        let session = URLSession(configuration: .ephemeral)

        let (apiData, _) = try await session.data(from: server.url(forPath: "/api/users"))
        #expect(String(data: apiData, encoding: .utf8)!.contains("/api/users"))

        let (htmlData, _) = try await session.data(from: server.url(forPath: "/page"))
        #expect(String(data: htmlData, encoding: .utf8) == "<h1>Fallback</h1>")
    }

    /// Use method-specific closure routes for REST-style endpoints.
    @Test func methodBasedClosureRoutes() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("GET", "/items") { _ in
            .json(#"{"action": "list"}"#)
        }
        server.route("POST", "/items") { _ in
            .json(#"{"action": "create"}"#, statusCode: 201)
        }

        let session = URLSession(configuration: .ephemeral)

        let (getData, _) = try await session.data(from: server.url(forPath: "/items"))
        #expect(String(data: getData, encoding: .utf8)!.contains("list"))

        var postReq = URLRequest(url: server.url(forPath: "/items"))
        postReq.httpMethod = "POST"
        let (postData, postResp) = try await session.data(for: postReq)
        #expect((postResp as! HTTPURLResponse).statusCode == 201)
        #expect(String(data: postData, encoding: .utf8)!.contains("create"))
    }
}
