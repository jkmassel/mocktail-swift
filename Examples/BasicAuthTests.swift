/// BasicAuthTests.swift
///
/// Demonstrates HTTP Basic Authentication testing with MockWebServer.
/// Copy these patterns into your own test target.

import Foundation
import Testing
import MockWebServer

@Suite struct BasicAuthTests {

    // MARK: - Basic Auth Challenge

    /// Test that the server returns a 401 with WWW-Authenticate header.
    /// Uses `withServer` for automatic setup and teardown.
    @Test func basicAuthChallenge() async throws {
        try await MockWebServer.withServer { server in
            // Use route instead of enqueue — routes persist across retries
            server.route("/protected", .basicAuthChallenge(realm: "Restricted Area"))

            let session = URLSession(configuration: .ephemeral)
            let (_, response) = try await session.data(from: server.url(forPath: "/protected"))

            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 401)
            #expect(http.value(forHTTPHeaderField: "WWW-Authenticate") == "Basic realm=\"Restricted Area\"")
        }
    }

    /// Test with default realm.
    @Test func basicAuthChallengeDefaultRealm() async throws {
        try await MockWebServer.withServer { server in
            server.route("/protected", .basicAuthChallenge())

            let session = URLSession(configuration: .ephemeral)
            let (_, response) = try await session.data(from: server.url(forPath: "/protected"))

            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 401)
            #expect(http.value(forHTTPHeaderField: "WWW-Authenticate") == "Basic realm=\"MockWebServer\"")
        }
    }

    /// Test with custom body.
    @Test func basicAuthChallengeWithCustomBody() async throws {
        try await MockWebServer.withServer { server in
            server.route("/protected", .basicAuthChallenge(realm: "API", body: "Authentication required"))

            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(from: server.url(forPath: "/protected"))

            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 401)
            #expect(http.value(forHTTPHeaderField: "WWW-Authenticate") == "Basic realm=\"API\"")
            #expect(String(data: data, encoding: .utf8) == "Authentication required")
        }
    }

    /// Test that 401 challenges persist until Basic credentials are provided.
    /// Uses `enqueueAuthChallenge(_:then:)` which keeps the 401 in the queue
    /// until a request with a `Basic` Authorization header arrives.
    @Test func basicAuthChallengeWithEnqueue() async throws {
        try await MockWebServer.withServer { server in
            server.enqueueAuthChallenge(
                .basicAuthChallenge(realm: "Test"),
                then: .json(#"{"status": "authenticated"}"#)
            )

            let session = URLSession(configuration: .ephemeral)
            let url = server.url(forPath: "/protected")

            // First request without auth → 401
            let (_, response1) = try await session.data(from: url)
            let http1 = try #require(response1 as? HTTPURLResponse)
            #expect(http1.statusCode == 401)

            // Second request with Basic credentials → 200
            var authRequest = URLRequest(url: url)
            let creds = Data("user:pass".utf8).base64EncodedString()
            authRequest.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
            let (data, response2) = try await session.data(for: authRequest)
            let http2 = try #require(response2 as? HTTPURLResponse)
            #expect(http2.statusCode == 200)
            let body = try #require(String(data: data, encoding: .utf8))
            #expect(body.contains("authenticated"))
        }
    }

    // MARK: - Extracting Basic Auth Credentials

    /// Test that we can extract credentials from a request's Authorization header.
    @Test func extractBasicAuthCredentials() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("Welcome"))

            let url = server.url(forPath: "/protected")
            var request = URLRequest(url: url)

            // Add Basic Auth header: "admin:secret123" -> base64
            let credentials = "admin:secret123"
            let base64 = Data(credentials.utf8).base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

            let session = URLSession(configuration: .ephemeral)
            _ = try await session.data(for: request)

            let recorded = await server.takeRequest()
            let req = try #require(recorded)

            let auth = try #require(req.basicAuthCredentials)
            #expect(auth.username == "admin")
            #expect(auth.password == "secret123")
        }
    }

    /// Test credentials with special characters (colon in password).
    @Test func extractCredentialsWithColonInPassword() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            let url = server.url(forPath: "/protected")
            var request = URLRequest(url: url)

            // Password contains colons: "user:pass:with:colons"
            let credentials = "user:pass:with:colons"
            let base64 = Data(credentials.utf8).base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

            let session = URLSession(configuration: .ephemeral)
            _ = try await session.data(for: request)

            let recorded = await server.takeRequest()
            let req = try #require(recorded)

            let auth = try #require(req.basicAuthCredentials)
            #expect(auth.username == "user")
            #expect(auth.password == "pass:with:colons")
        }
    }

    /// Test that missing Authorization header returns nil.
    @Test func noAuthHeaderReturnsNil() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            let session = URLSession(configuration: .ephemeral)
            _ = try await session.data(from: server.url(forPath: "/public"))

            let recorded = await server.takeRequest()
            let req = try #require(recorded)

            #expect(req.basicAuthCredentials == nil)
        }
    }

    /// Test that non-Basic auth scheme returns nil.
    @Test func nonBasicSchemeReturnsNil() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            let url = server.url(forPath: "/protected")
            var request = URLRequest(url: url)
            request.setValue("Bearer some-token", forHTTPHeaderField: "Authorization")

            let session = URLSession(configuration: .ephemeral)
            _ = try await session.data(for: request)

            let recorded = await server.takeRequest()
            let req = try #require(recorded)

            #expect(req.basicAuthCredentials == nil)
        }
    }

    // MARK: - Dynamic Route with Auth Validation

    /// Use a closure route to validate credentials and return different responses.
    /// This is the recommended pattern for testing authentication flows.
    @Test func dynamicAuthValidation() async throws {
        try await MockWebServer.withServer { server in
            server.route("/api/secure") { request in
                guard let auth = request.basicAuthCredentials,
                      auth.username == "validuser",
                      auth.password == "validpass" else {
                    return .basicAuthChallenge(realm: "API")
                }
                return .json(#"{"message": "Authenticated!"}"#)
            }

            let session = URLSession(configuration: .ephemeral)
            let url = server.url(forPath: "/api/secure")

            // Without credentials: 401
            let (_, response1) = try await session.data(from: url)
            let http1 = try #require(response1 as? HTTPURLResponse)
            #expect(http1.statusCode == 401)

            // With wrong credentials: 401
            var badRequest = URLRequest(url: url)
            let badCreds = Data("wrong:creds".utf8).base64EncodedString()
            badRequest.setValue("Basic \(badCreds)", forHTTPHeaderField: "Authorization")
            let (_, response2) = try await session.data(for: badRequest)
            let http2 = try #require(response2 as? HTTPURLResponse)
            #expect(http2.statusCode == 401)

            // With correct credentials: 200
            var goodRequest = URLRequest(url: url)
            let goodCreds = Data("validuser:validpass".utf8).base64EncodedString()
            goodRequest.setValue("Basic \(goodCreds)", forHTTPHeaderField: "Authorization")
            let (data, response3) = try await session.data(for: goodRequest)
            let http3 = try #require(response3 as? HTTPURLResponse)
            #expect(http3.statusCode == 200)
            let body = try #require(String(data: data, encoding: .utf8))
            #expect(body.contains("Authenticated"))
        }
    }

    /// Full authentication flow using dynamic route.
    /// Demonstrates the recommended approach for testing auth: use a closure route
    /// that validates credentials and returns appropriate responses.
    @Test func fullAuthenticationFlow() async throws {
        try await MockWebServer.withServer { server in
            // Route that checks for valid credentials
            server.route("/admin") { request in
                guard let auth = request.basicAuthCredentials,
                      auth.username == "admin",
                      auth.password == "supersecret" else {
                    return .basicAuthChallenge(realm: "Admin Panel")
                }
                return .json(#"{"user": "admin", "role": "administrator"}"#)
            }

            let session = URLSession(configuration: .ephemeral)
            let url = server.url(forPath: "/admin")

            // First attempt: no credentials -> 401
            let (_, response1) = try await session.data(from: url)
            let http1 = try #require(response1 as? HTTPURLResponse)
            #expect(http1.statusCode == 401)
            #expect(http1.value(forHTTPHeaderField: "WWW-Authenticate") == "Basic realm=\"Admin Panel\"")

            // Second attempt: with correct credentials -> 200
            var authRequest = URLRequest(url: url)
            let credentials = "admin:supersecret"
            let base64 = Data(credentials.utf8).base64EncodedString()
            authRequest.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

            let (data, response2) = try await session.data(for: authRequest)
            let http2 = try #require(response2 as? HTTPURLResponse)
            #expect(http2.statusCode == 200)
            let body = try #require(String(data: data, encoding: .utf8))
            #expect(body.contains("administrator"))

            // At least 2 hits: the unauthenticated request + the authenticated one.
            // URLSession may internally retry the 401 before returning, adding
            // extra hits that are outside our control.
            #expect(server.routeHitCount(forPath: "/admin") >= 2)
        }
    }
}
