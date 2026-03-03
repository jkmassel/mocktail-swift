import Foundation
import Testing
@testable import MockWebServer

@Suite struct RateLimitHelperTests {

    // MARK: - MockResponse.rateLimited factory

    @Test func rateLimitedDefaultBody() {
        let response = MockResponse.rateLimited(retryAfter: 30)
        #expect(response.statusCode == 429)
        #expect(response.body == Data("Too Many Requests".utf8))

        let retryAfter = response.headers.first { $0.0 == "Retry-After" }
        #expect(retryAfter?.1 == "30")

        let contentType = response.headers.first { $0.0 == "Content-Type" }
        #expect(contentType?.1 == "text/plain; charset=utf-8")
    }

    @Test func rateLimitedWithJSONBody() {
        let json = #"{"error": "rate_limited"}"#
        let response = MockResponse.rateLimited(retryAfter: 60, body: .json(json))
        #expect(response.statusCode == 429)
        #expect(response.body == Data(json.utf8))

        let retryAfter = response.headers.first { $0.0 == "Retry-After" }
        #expect(retryAfter?.1 == "60")

        let contentType = response.headers.first { $0.0 == "Content-Type" }
        #expect(contentType?.1 == "application/json")
    }

    @Test func rateLimitedWithHTMLBody() {
        let html = "<p>Rate limited</p>"
        let response = MockResponse.rateLimited(retryAfter: 10, body: .html(html))
        #expect(response.statusCode == 429)
        #expect(response.body == Data(html.utf8))

        let contentType = response.headers.first { $0.0 == "Content-Type" }
        #expect(contentType?.1 == "text/html; charset=utf-8")
    }

    @Test func rateLimitedWithZeroRetryAfter() {
        let response = MockResponse.rateLimited(retryAfter: 0)
        #expect(response.statusCode == 429)
        #expect(response.body == Data("Too Many Requests".utf8))

        let retryAfter = response.headers.first { $0.0 == "Retry-After" }
        #expect(retryAfter?.1 == "0")
    }

    @Test func rateLimitedComposesWithBuilders() {
        let response = MockResponse.rateLimited(retryAfter: 5)
            .withHeader("X-RateLimit-Remaining", "0")
        #expect(response.statusCode == 429)
        #expect(response.headers.contains { $0.0 == "Retry-After" && $0.1 == "5" })
        #expect(response.headers.contains { $0.0 == "X-RateLimit-Remaining" && $0.1 == "0" })
    }

    // MARK: - ResponseBody enum

    @Test func responseBodyJSONContent() {
        let body = ResponseBody.json(#"{"key": "value"}"#)
        #expect(body.content == #"{"key": "value"}"#)
        #expect(body.contentType == "application/json")
    }

    @Test func responseBodyHTMLContent() {
        let body = ResponseBody.html("<h1>Hello</h1>")
        #expect(body.content == "<h1>Hello</h1>")
        #expect(body.contentType == "text/html; charset=utf-8")
    }

    @Test func responseBodyTextContent() {
        let body = ResponseBody.text("plain text")
        #expect(body.content == "plain text")
        #expect(body.contentType == "text/plain; charset=utf-8")
    }

    // MARK: - withBody(ResponseBody) builder

    @Test func withBodySetsBodyAndContentType() {
        let response = MockResponse(statusCode: 200)
            .withBody(.json(#"{"ok": true}"#))
        #expect(response.body == Data(#"{"ok": true}"#.utf8))

        let contentType = response.headers.first { $0.0 == "Content-Type" }
        #expect(contentType?.1 == "application/json")
    }

    @Test func withBodyOverridesPreviousBody() {
        let response = MockResponse(statusCode: 200)
            .withBody(.text("first"))
            .withBody(.json("{}"))
        #expect(response.body == Data("{}".utf8))

        // Content-Type is replaced, not accumulated
        let contentTypes = response.headers.filter { $0.0 == "Content-Type" }
        #expect(contentTypes.count == 1)
        #expect(contentTypes.first?.1 == "application/json")
    }

    @Test func withBodyReplacesContentTypeFromFactory() {
        // .rateLimited already sets Content-Type; withBody should replace it
        let response = MockResponse.rateLimited(retryAfter: 30)
            .withBody(.json(#"{"error": "rate_limited"}"#))
        let contentTypes = response.headers.filter { $0.0 == "Content-Type" }
        #expect(contentTypes.count == 1)
        #expect(contentTypes.first?.1 == "application/json")
        #expect(response.body == Data(#"{"error": "rate_limited"}"#.utf8))
    }

    @Test func withBodyReplacesContentTypeFromJsonFactory() {
        // .json() sets Content-Type; withBody(.html) should replace it
        let response = MockResponse.json("{}")
            .withBody(.html("<p>changed</p>"))
        let contentTypes = response.headers.filter { $0.0 == "Content-Type" }
        #expect(contentTypes.count == 1)
        #expect(contentTypes.first?.1 == "text/html; charset=utf-8")
        #expect(response.body == Data("<p>changed</p>".utf8))
    }

    // MARK: - HTTPParser serializes 429 correctly

    @Test func serializeRateLimitedResponse() throws {
        let response = MockResponse.rateLimited(retryAfter: 30, body: .text("rate limit exceeded"))
        let data = HTTPParser.serializeResponse(response)
        let string = try #require(String(data: data, encoding: .utf8))

        #expect(string.hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"))
        #expect(string.contains("Retry-After: 30\r\n"))
        #expect(string.contains("Content-Type: text/plain; charset=utf-8\r\n"))
        // Use a distinct body that can't be confused with the HTTP reason phrase
        #expect(string.hasSuffix("rate limit exceeded"))
    }

    // MARK: - enqueueRateLimited convenience (integration)

    @Test func enqueueRateLimitedServesTwo() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueueRateLimited(retryAfter: 1, then: .json(#"{"ok": true}"#))

        let session = URLSession(configuration: .ephemeral)
        let url = server.url(forPath: "/test")

        // First request: 429
        let (_, r1) = try await session.data(from: url)
        let http1 = try #require(r1 as? HTTPURLResponse)
        #expect(http1.statusCode == 429)
        #expect(http1.value(forHTTPHeaderField: "Retry-After") == "1")

        // Second request: success
        let (data, r2) = try await session.data(from: url)
        let http2 = try #require(r2 as? HTTPURLResponse)
        #expect(http2.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"{"ok": true}"#)

        // Queue is empty — third request gets 500
        let (_, r3) = try await session.data(from: url)
        let http3 = try #require(r3 as? HTTPURLResponse)
        #expect(http3.statusCode == 500)
    }

    @Test func rateLimitedResponseRetryAfterHeaderOverNetwork() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.rateLimited(retryAfter: 120, body: .json(#"{"error": "slow_down"}"#)))

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: server.url(forPath: "/api"))

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 429)
        #expect(http.value(forHTTPHeaderField: "Retry-After") == "120")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(data: data, encoding: .utf8) == #"{"error": "slow_down"}"#)
    }

    // MARK: - Empty string edge cases

    @Test func responseBodyWithEmptyStrings() {
        let jsonBody = ResponseBody.json("")
        #expect(jsonBody.content == "")
        #expect(jsonBody.contentData == Data())
        #expect(jsonBody.contentType == "application/json")

        let textBody = ResponseBody.text("")
        #expect(textBody.content == "")
        #expect(textBody.contentData == Data())
        #expect(textBody.contentType == "text/plain; charset=utf-8")

        let htmlBody = ResponseBody.html("")
        #expect(htmlBody.content == "")
        #expect(htmlBody.contentData == Data())
        #expect(htmlBody.contentType == "text/html; charset=utf-8")
    }

    // MARK: - ResponseBody.data case

    @Test func responseBodyDataCase() {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        let body = ResponseBody.data(pngData, contentType: "image/png")
        #expect(body.contentData == pngData)
        #expect(body.contentType == "image/png")
    }

    @Test func withBodyDataCaseOverNetwork() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        let binaryData = Data([0x00, 0x01, 0x02, 0xFF])
        server.enqueue(
            MockResponse(statusCode: 200)
                .withBody(.data(binaryData, contentType: "application/octet-stream"))
        )

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: server.url(forPath: "/binary"))

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(data == binaryData)
    }

    // MARK: - enqueueRateLimited with custom body

    @Test func enqueueRateLimitedWithCustomBody() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueueRateLimited(
            retryAfter: 5,
            body: .json(#"{"error": "slow_down"}"#),
            then: .json(#"{"ok": true}"#)
        )

        let session = URLSession(configuration: .ephemeral)
        let url = server.url(forPath: "/api")

        // First request: 429 with JSON body
        let (errorData, r1) = try await session.data(from: url)
        let http1 = try #require(r1 as? HTTPURLResponse)
        #expect(http1.statusCode == 429)
        #expect(http1.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(data: errorData, encoding: .utf8) == #"{"error": "slow_down"}"#)

        // Second request: success
        let (data, r2) = try await session.data(from: url)
        let http2 = try #require(r2 as? HTTPURLResponse)
        #expect(http2.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"{"ok": true}"#)
    }
}
