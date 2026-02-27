import Foundation
import Testing
@testable import MockWebServer

@Suite struct HTTPParserTests {

    @Test func parseSimpleGetRequest() throws {
        let raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = try #require(HTTPParser.parseRequest(from: Data(raw.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/hello")
        #expect(request.body == nil)
    }

    @Test func parsePostRequestWithBody() throws {
        let raw = "POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello"
        let request = try #require(HTTPParser.parseRequest(from: Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/submit")
        #expect(request.body == Data("hello".utf8))
    }

    @Test func parseRequestHeaders() throws {
        let raw = "GET / HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\nX-Custom: value\r\n\r\n"
        let request = try #require(HTTPParser.parseRequest(from: Data(raw.utf8)))
        #expect(request.headers.count == 3)

        let hostHeader = request.headers.first { $0.0 == "Host" }
        #expect(hostHeader?.1 == "localhost")

        let customHeader = request.headers.first { $0.0 == "X-Custom" }
        #expect(customHeader?.1 == "value")
    }

    @Test func returnsNilForIncompleteHeaders() throws {
        let raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\n"
        let request = HTTPParser.parseRequest(from: Data(raw.utf8))
        #expect(request == nil)
    }

    @Test func returnsNilForIncompleteBody() throws {
        let raw = "POST /submit HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
        let request = HTTPParser.parseRequest(from: Data(raw.utf8))
        #expect(request == nil)
    }

    @Test func serializeBasicResponse() throws {
        let response = MockResponse(statusCode: 200).withBody("OK")
        let data = HTTPParser.serializeResponse(response)
        let string = try #require(String(data: data, encoding: .utf8))

        #expect(string.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(string.contains("Content-Length: 2\r\n"))
        #expect(string.contains("Connection: close\r\n"))
        #expect(string.hasSuffix("\r\n\r\nOK"))
    }

    @Test func serializeResponseWithCustomHeaders() throws {
        let response = MockResponse(statusCode: 201)
            .withHeader("X-Foo", "bar")
            .withBody("created")
        let data = HTTPParser.serializeResponse(response)
        let string = try #require(String(data: data, encoding: .utf8))

        #expect(string.hasPrefix("HTTP/1.1 201 Created\r\n"))
        #expect(string.contains("X-Foo: bar\r\n"))
    }

    @Test func serializeEmptyBodyResponse() throws {
        let response = MockResponse(statusCode: 204)
        let data = HTTPParser.serializeResponse(response)
        let string = try #require(String(data: data, encoding: .utf8))

        #expect(string.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(string.contains("Content-Length: 0\r\n"))
    }
}
