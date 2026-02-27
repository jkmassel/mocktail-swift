import Foundation
import Testing
@testable import MockWebServer

@Suite(.serialized) struct TLSTests {

    @Test func loadLocalhostCertificate() throws {
        let tls = try TLSConfiguration.localhost()
        _ = tls // Successfully loaded
    }

    @Test func loadExpiredCertificate() throws {
        let tls = try TLSConfiguration.expired()
        _ = tls
    }

    @Test func loadWrongHostnameCertificate() throws {
        let tls = try TLSConfiguration.wrongHostname()
        _ = tls
    }

    @Test func httpsServerStartsWithValidCert() async throws {
        let server = MockWebServer()
        let tls = try TLSConfiguration.localhost()
        try server.start(tls: tls)
        defer { server.shutdown() }

        #expect(server.port > 0)

        let url = server.url(forPath: "/secure")
        #expect(url.scheme == "https")
    }

    @Test func httpsRequestWithSelfSignedCert() async throws {
        let server = MockWebServer()
        let tls = try TLSConfiguration.localhost()
        try server.start(tls: tls)
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody("secure"))

        // URLSession will reject self-signed certs by default
        let url = server.url(forPath: "/secure")
        let delegate = TrustAllDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

        let (data, response) = try await session.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "secure")
    }

    @Test func httpsToPlainHTTPServer() async throws {
        let server = MockWebServer()
        try server.start() // plain HTTP
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody("Hello"))

        // Try to connect via HTTPS to a plain HTTP server
        let httpsURL = URL(string: "https://127.0.0.1:\(server.port)/test")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: httpsURL)
            Issue.record("Expected an error when connecting via HTTPS to HTTP server")
        } catch {
            // Expected — TLS handshake fails against plain TCP
        }
    }
}

/// A URLSessionDelegate that trusts all server certificates (for testing self-signed certs).
private final class TrustAllDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
