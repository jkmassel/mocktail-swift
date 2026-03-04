import Foundation
import Testing
@testable import MockWebServer

@Suite struct BasicAuthUnitTests {

    // MARK: - Credential Parsing

    @Test func caseInsensitiveScheme() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            // "basic " (lowercase) should still match per RFC 7235
            var request = URLRequest(url: server.url(forPath: "/test"))
            let base64 = Data("user:pass".utf8).base64EncodedString()
            request.setValue("basic \(base64)", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            let auth = try #require(recorded.basicAuthCredentials)
            #expect(auth.username == "user")
            #expect(auth.password == "pass")
        }
    }

    @Test func uppercaseScheme() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            var request = URLRequest(url: server.url(forPath: "/test"))
            let base64 = Data("user:pass".utf8).base64EncodedString()
            request.setValue("BASIC \(base64)", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            let auth = try #require(recorded.basicAuthCredentials)
            #expect(auth.username == "user")
            #expect(auth.password == "pass")
        }
    }

    @Test func bearerTokenReturnsNil() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            var request = URLRequest(url: server.url(forPath: "/test"))
            request.setValue("Bearer some-token", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            #expect(recorded.basicAuthCredentials == nil)
        }
    }

    @Test func malformedBase64ReturnsNil() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            var request = URLRequest(url: server.url(forPath: "/test"))
            request.setValue("Basic !!!not-base64!!!", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            #expect(recorded.basicAuthCredentials == nil)
        }
    }

    @Test func noColonInDecodedValueReturnsNil() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            var request = URLRequest(url: server.url(forPath: "/test"))
            let base64 = Data("nocolon".utf8).base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            #expect(recorded.basicAuthCredentials == nil)
        }
    }

    @Test func emptyUsername() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            var request = URLRequest(url: server.url(forPath: "/test"))
            let base64 = Data(":password".utf8).base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            let auth = try #require(recorded.basicAuthCredentials)
            #expect(auth.username == "")
            #expect(auth.password == "password")
        }
    }

    @Test func emptyPassword() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            var request = URLRequest(url: server.url(forPath: "/test"))
            let base64 = Data("user:".utf8).base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            let auth = try #require(recorded.basicAuthCredentials)
            #expect(auth.username == "user")
            #expect(auth.password == "")
        }
    }

    @Test func colonInPassword() async throws {
        try await MockWebServer.withServer { server in
            server.enqueue(.text("ok"))

            var request = URLRequest(url: server.url(forPath: "/test"))
            let base64 = Data("user:a:b:c".utf8).base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

            _ = try await URLSession(configuration: .ephemeral).data(for: request)

            let recorded = try #require(await server.takeRequest())
            let auth = try #require(recorded.basicAuthCredentials)
            #expect(auth.username == "user")
            #expect(auth.password == "a:b:c")
        }
    }

    // MARK: - basicAuthChallenge Response

    @Test func basicAuthChallengeHasContentType() async throws {
        try await MockWebServer.withServer { server in
            server.route("/test", .basicAuthChallenge())

            let (_, response) = try await URLSession(configuration: .ephemeral)
                .data(from: server.url(forPath: "/test"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "text/plain; charset=utf-8")
        }
    }

    @Test func basicAuthChallengeDefaultValues() async throws {
        try await MockWebServer.withServer { server in
            server.route("/test", .basicAuthChallenge())

            let (data, response) = try await URLSession(configuration: .ephemeral)
                .data(from: server.url(forPath: "/test"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 401)
            #expect(http.value(forHTTPHeaderField: "WWW-Authenticate") == #"Basic realm="MockWebServer""#)
            #expect(String(data: data, encoding: .utf8) == "Unauthorized")
        }
    }

    @Test func basicAuthChallengeEscapesQuotesInRealm() async throws {
        try await MockWebServer.withServer { server in
            server.route("/test", .basicAuthChallenge(realm: #"say "hello""#))

            let (_, response) = try await URLSession(configuration: .ephemeral)
                .data(from: server.url(forPath: "/test"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.value(forHTTPHeaderField: "WWW-Authenticate") == #"Basic realm="say \"hello\"""#)
        }
    }

    @Test func basicAuthChallengeEscapesBackslashInRealm() async throws {
        try await MockWebServer.withServer { server in
            server.route("/test", .basicAuthChallenge(realm: #"path\to\thing"#))

            let (_, response) = try await URLSession(configuration: .ephemeral)
                .data(from: server.url(forPath: "/test"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.value(forHTTPHeaderField: "WWW-Authenticate") == #"Basic realm="path\\to\\thing""#)
        }
    }

    // MARK: - enqueueAuthChallenge Queue Behavior

    @Test func bearerTokenDoesNotConsumeAuthChallenge() async throws {
        try await MockWebServer.withServer { server in
            server.enqueueAuthChallenge(
                .basicAuthChallenge(realm: "Test"),
                then: .json(#"{"ok": true}"#)
            )

            let session = URLSession(configuration: .ephemeral)
            let url = server.url(forPath: "/test")

            // Send Bearer token — should NOT consume the auth challenge
            var bearerRequest = URLRequest(url: url)
            bearerRequest.setValue("Bearer some-token", forHTTPHeaderField: "Authorization")
            let (_, response1) = try await session.data(for: bearerRequest)
            let http1 = try #require(response1 as? HTTPURLResponse)
            #expect(http1.statusCode == 401)

            // Send Basic credentials — should consume challenge and return success
            var basicRequest = URLRequest(url: url)
            let creds = Data("user:pass".utf8).base64EncodedString()
            basicRequest.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
            let (data, response2) = try await session.data(for: basicRequest)
            let http2 = try #require(response2 as? HTTPURLResponse)
            #expect(http2.statusCode == 200)
            let body = try #require(String(data: data, encoding: .utf8))
            #expect(body.contains("ok"))
        }
    }

    @Test func enqueueAuthChallengeFlow() async throws {
        try await MockWebServer.withServer { server in
            server.enqueueAuthChallenge(
                .basicAuthChallenge(realm: "API"),
                then: .text("Welcome")
            )

            let session = URLSession(configuration: .ephemeral)
            let url = server.url(forPath: "/resource")

            // Without auth → 401
            let (_, response1) = try await session.data(from: url)
            let http1 = try #require(response1 as? HTTPURLResponse)
            #expect(http1.statusCode == 401)

            // With Basic auth → 200
            var authRequest = URLRequest(url: url)
            let creds = Data("user:pass".utf8).base64EncodedString()
            authRequest.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
            let (data, response2) = try await session.data(for: authRequest)
            let http2 = try #require(response2 as? HTTPURLResponse)
            #expect(http2.statusCode == 200)
            #expect(String(data: data, encoding: .utf8) == "Welcome")
        }
    }

    @Test func unauthenticatedRequestsRepeatChallenge() async throws {
        try await MockWebServer.withServer { server in
            server.enqueueAuthChallenge(
                .basicAuthChallenge(realm: "Test"),
                then: .text("OK")
            )

            let session = URLSession(configuration: .ephemeral)
            let url = server.url(forPath: "/test")

            // Multiple unauthenticated requests all get 401
            for _ in 0..<3 {
                let (_, response) = try await session.data(from: url)
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 401)
            }

            // Then authenticate
            var authRequest = URLRequest(url: url)
            let creds = Data("u:p".utf8).base64EncodedString()
            authRequest.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: authRequest)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
        }
    }

    /// Documents why `enqueueAuthChallenge` exists: with plain `enqueue`,
    /// URLSession's automatic 401 retry consumes both responses in a single call,
    /// so the caller never sees the 401. `enqueueAuthChallenge` fixes this by
    /// persisting the challenge until explicit Basic credentials arrive.
    @Test func plainEnqueueIsConsumedByURLSessionRetry() async throws {
        try await MockWebServer.withServer { server in
            // Plain enqueue: URLSession's internal retry consumes both responses
            server.enqueue(.basicAuthChallenge(realm: "Test"))
            server.enqueue(.text("after-auth"))

            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(from: server.url(forPath: "/test"))
            let http = try #require(response as? HTTPURLResponse)
            // URLSession retried automatically, so the caller sees the second response
            #expect(http.statusCode == 200)
            #expect(String(data: data, encoding: .utf8) == "after-auth")
        }
    }
}
