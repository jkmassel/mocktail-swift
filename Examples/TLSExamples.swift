/// TLSExamples.swift
///
/// Demonstrates how to use MockWebServer for HTTPS and TLS error testing.
/// These examples show how to test certificate validation scenarios that
/// cannot be tested with URL protocol stubs.

import Foundation
import Testing
import MockWebServer

@Suite(.serialized) struct TLSExamples {

    // MARK: - HTTPS with self-signed certificate

    /// Start the server with a self-signed localhost certificate.
    /// Use a custom URLSessionDelegate to trust the cert.
    @Test func httpsWithSelfSignedCert() async throws {
        let server = MockWebServer()
        let tls = try TLSConfiguration.localhost()
        try server.start(tls: tls)
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody(.text("Secure response")))

        let url = server.url(forPath: "/api/data")
        #expect(url.scheme == "https")

        // Trust all certs for testing
        let delegate = TrustAllCertsDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)

        let (data, response) = try await session.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "Secure response")
    }

    // MARK: - HTTPS to plain HTTP server (protocol mismatch)

    /// Test that your code handles the case where it tries to connect
    /// via HTTPS to a server that only speaks HTTP.
    @Test func httpsToHTTPOnly() async throws {
        let server = MockWebServer()
        try server.start() // plain HTTP, no TLS
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody(.text("Hello")))

        // Construct an HTTPS URL pointing at the plain HTTP server
        let httpsURL = URL(string: "https://127.0.0.1:\(server.port)/api/data")!

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: httpsURL)
            Issue.record("Expected TLS handshake failure")
        } catch {
            // This is the error your app should map to
            // "HTTPS not supported" or similar
        }
    }

    // MARK: - Expired certificate

    /// Test that URLSession rejects an expired server certificate.
    @Test func expiredCertificate() async throws {
        let server = MockWebServer()
        let tls = try TLSConfiguration.expired()
        try server.start(tls: tls)
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200))

        let url = server.url(forPath: "/api/data")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: url)
            Issue.record("Expected certificate validation error")
        } catch {
            // URLSession should reject the expired certificate
        }
    }

    // MARK: - Wrong hostname certificate

    /// Test that URLSession rejects a certificate whose hostname doesn't match.
    @Test func wrongHostnameCertificate() async throws {
        let server = MockWebServer()
        let tls = try TLSConfiguration.wrongHostname()
        try server.start(tls: tls)
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200))

        // The cert is for "wrong.example.com", not "127.0.0.1"
        let url = server.url(forPath: "/api/data")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: url)
            Issue.record("Expected hostname mismatch error")
        } catch {
            // URLSession should reject the wrong-hostname certificate
        }
    }
}

// MARK: - Helper

private final class TrustAllCertsDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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
