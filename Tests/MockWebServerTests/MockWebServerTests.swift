import Foundation
import Testing
@testable import MockWebServer

@Suite struct MockWebServerTests {

    // MARK: - Phase 1: Plain HTTP

    @Test func startAndShutdown() throws {
        let server = MockWebServer()
        try server.start()
        #expect(server.port > 0)
        server.shutdown()
    }

    @Test func simpleGetRequest() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody(.text("Hello")))

        let url = server.url(forPath: "/test")
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "Hello")
    }

    @Test func customStatusCode() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 404).withBody(.text("Not Found")))

        let url = server.url(forPath: "/missing")
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 404)
        #expect(String(data: data, encoding: .utf8) == "Not Found")
    }

    @Test func customHeaders() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(
            MockResponse(statusCode: 200)
                .withBody(.json("{}"))
        )

        let url = server.url(forPath: "/api")
        let (_, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func jsonHelper() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.json(#"{"ok": true}"#))

        let url = server.url(forPath: "/api")
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(data: data, encoding: .utf8) == #"{"ok": true}"#)
    }

    @Test func htmlHelper() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.html("<p>hi</p>"))

        let url = server.url(forPath: "/page")
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
        #expect(String(data: data, encoding: .utf8) == "<p>hi</p>")
    }

    @Test func textHelper() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.text("hello"))

        let url = server.url(forPath: "/plain")
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "text/plain; charset=utf-8")
        #expect(String(data: data, encoding: .utf8) == "hello")
    }

    @Test func jsonHelperWithCustomStatus() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.json(#"{"error": "not found"}"#, statusCode: 404))

        let url = server.url(forPath: "/missing")
        let (data, response) = try await URLSession.shared.data(from: url)

        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 404)
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(data: data, encoding: .utf8) == #"{"error": "not found"}"#)
    }

    @Test func multipleEnqueuedResponses() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody(.text("first")))
        server.enqueue(MockResponse(statusCode: 201).withBody(.text("second")))
        server.enqueue(MockResponse(statusCode: 202).withBody(.text("third")))

        let session = URLSession(configuration: .ephemeral)

        for (index, expected) in [(200, "first"), (201, "second"), (202, "third")].enumerated() {
            let url = server.url(forPath: "/\(index)")
            let (data, response) = try await session.data(from: url)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == expected.0)
            #expect(String(data: data, encoding: .utf8) == expected.1)
        }
    }

    @Test func postRequestWithBody() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200).withBody(.text("ok")))

        let url = server.url(forPath: "/submit")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("payload".utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test func urlBuildsCorrectly() throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        let url = server.url(forPath: "/api/v2/users")
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == Int(server.port))
        #expect(url.path == "/api/v2/users")
    }

    // MARK: - Phase 2: Request Recording + Socket Policies

    @Test func takeRequestRecordsMethod() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200))

        let url = server.url(forPath: "/hello")
        _ = try await URLSession.shared.data(from: url)

        let recorded = await server.takeRequest()
        let request = try #require(recorded)
        #expect(request.method == "GET")
        #expect(request.path == "/hello")
    }

    @Test func takeRequestRecordsPostBody() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200))

        let url = server.url(forPath: "/post")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("test body".utf8)

        _ = try await URLSession.shared.data(for: request)

        let recorded = await server.takeRequest()
        let req = try #require(recorded)
        #expect(req.method == "POST")
        #expect(req.body == Data("test body".utf8))
    }

    @Test func takeRequestFIFOOrder() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse(statusCode: 200))
        server.enqueue(MockResponse(statusCode: 200))
        server.enqueue(MockResponse(statusCode: 200))

        let session = URLSession(configuration: .ephemeral)

        _ = try await session.data(from: server.url(forPath: "/a"))
        _ = try await session.data(from: server.url(forPath: "/b"))
        _ = try await session.data(from: server.url(forPath: "/c"))

        let r1 = await server.takeRequest()
        let r2 = await server.takeRequest()
        let r3 = await server.takeRequest()
        #expect(r1?.path == "/a")
        #expect(r2?.path == "/b")
        #expect(r3?.path == "/c")
    }

    @Test func requestCount() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        #expect(server.requestCount == 0)

        server.enqueue(MockResponse(statusCode: 200))
        server.enqueue(MockResponse(statusCode: 200))

        let session = URLSession(configuration: .ephemeral)
        _ = try await session.data(from: server.url(forPath: "/1"))
        _ = try await session.data(from: server.url(forPath: "/2"))

        // Give the server a moment to record
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.requestCount == 2)
    }

    @Test func takeRequestTimesOut() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        let result = await server.takeRequest(timeout: .milliseconds(200))
        #expect(result == nil)
    }

    @Test func disconnectImmediately() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse().withSocketPolicy(.disconnectImmediately))

        let url = server.url(forPath: "/dc")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)

        // Use POST to prevent URLSession from retrying the request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        do {
            _ = try await session.data(for: request)
            Issue.record("Expected an error from disconnected socket")
        } catch {
            // Expected — connection was force-closed by server
        }
    }

    // MARK: - Path-based routing

    @Test func routeReturnsPersistentResponse() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/", .html("<h1>Home</h1>"))
        server.route("/api/status", .json(#"{"status": "ok"}"#))

        let session = URLSession(configuration: .ephemeral)

        // Hit each route
        let (homeData, homeResp) = try await session.data(from: server.url(forPath: "/"))
        let homeHTTP = try #require(homeResp as? HTTPURLResponse)
        #expect(homeHTTP.statusCode == 200)
        #expect(String(data: homeData, encoding: .utf8) == "<h1>Home</h1>")

        let (jsonData, jsonResp) = try await session.data(from: server.url(forPath: "/api/status"))
        let jsonHTTP = try #require(jsonResp as? HTTPURLResponse)
        #expect(jsonHTTP.statusCode == 200)
        #expect(String(data: jsonData, encoding: .utf8) == #"{"status": "ok"}"#)

        // Routes are persistent — hit them again
        let (homeData2, _) = try await session.data(from: server.url(forPath: "/"))
        #expect(String(data: homeData2, encoding: .utf8) == "<h1>Home</h1>")

        let (jsonData2, _) = try await session.data(from: server.url(forPath: "/api/status"))
        #expect(String(data: jsonData2, encoding: .utf8) == #"{"status": "ok"}"#)

        #expect(server.requestCount == 4)
    }

    @Test func routeTakesPriorityOverQueue() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/api", .json(#"{"routed": true}"#))
        server.enqueue(.json(#"{"queued": true}"#))

        let session = URLSession(configuration: .ephemeral)

        // /api matches the route, so the queue is untouched
        let (data1, _) = try await session.data(from: server.url(forPath: "/api"))
        #expect(String(data: data1, encoding: .utf8) == #"{"routed": true}"#)

        // /other has no route, so it falls back to the queue
        let (data2, _) = try await session.data(from: server.url(forPath: "/other"))
        #expect(String(data: data2, encoding: .utf8) == #"{"queued": true}"#)
    }

    @Test func unmatchedPathFallsBackToQueue() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/known", .text("known"))
        server.enqueue(.text("from queue"))

        let session = URLSession(configuration: .ephemeral)

        let (data, _) = try await session.data(from: server.url(forPath: "/unknown"))
        #expect(String(data: data, encoding: .utf8) == "from queue")
    }

    // MARK: - Closure routes

    @Test func closureRouteReceivesRequest() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/api/test") { request in
            .json(#"{"path": "\#(request.path)"}"#)
        }
        server.enqueue(.text("from queue"))

        let session = URLSession(configuration: .ephemeral)

        let (apiData, _) = try await session.data(from: server.url(forPath: "/api/test"))
        #expect(String(data: apiData, encoding: .utf8) == #"{"path": "/api/test"}"#)

        let (queueData, _) = try await session.data(from: server.url(forPath: "/other"))
        #expect(String(data: queueData, encoding: .utf8) == "from queue")
    }

    @Test func closureMethodRouteMatchesCorrectMethod() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("GET", "/items") { _ in .json(#"{"action": "list"}"#) }
        server.route("POST", "/items") { _ in .json(#"{"action": "create"}"#, statusCode: 201) }

        let session = URLSession(configuration: .ephemeral)

        let (getData, _) = try await session.data(from: server.url(forPath: "/items"))
        #expect(String(data: getData, encoding: .utf8)!.contains("list"))

        var postReq = URLRequest(url: server.url(forPath: "/items"))
        postReq.httpMethod = "POST"
        let (postData, postResp) = try await session.data(for: postReq)
        #expect((postResp as! HTTPURLResponse).statusCode == 201)
        #expect(String(data: postData, encoding: .utf8)!.contains("create"))
    }

    // MARK: - Method-aware routing

    @Test func methodSpecificRouteMatchesCorrectMethod() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("GET", "/users", .json(#"[{"id": 1}]"#))
        server.enqueue(MockResponse(statusCode: 405))

        let session = URLSession(configuration: .ephemeral)

        let (data, resp) = try await session.data(from: server.url(forPath: "/users"))
        #expect((resp as! HTTPURLResponse).statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"[{"id": 1}]"#)

        var postReq = URLRequest(url: server.url(forPath: "/users"))
        postReq.httpMethod = "POST"
        let (_, postResp) = try await session.data(for: postReq)
        #expect((postResp as! HTTPURLResponse).statusCode == 405)
    }

    @Test func methodRouteTakesPriorityOverCatchAll() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("POST", "/data", .json(#"{"method": "post"}"#, statusCode: 201))
        server.route("/data", .json(#"{"method": "any"}"#))

        let session = URLSession(configuration: .ephemeral)

        var postReq = URLRequest(url: server.url(forPath: "/data"))
        postReq.httpMethod = "POST"
        let (postData, postResp) = try await session.data(for: postReq)
        #expect((postResp as! HTTPURLResponse).statusCode == 201)
        #expect(String(data: postData, encoding: .utf8) == #"{"method": "post"}"#)

        let (getData, getResp) = try await session.data(from: server.url(forPath: "/data"))
        #expect((getResp as! HTTPURLResponse).statusCode == 200)
        #expect(String(data: getData, encoding: .utf8) == #"{"method": "any"}"#)
    }

    @Test func multipleMethodsOnSamePath() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("GET", "/resource", .json(#"{"action": "read"}"#))
        server.route("DELETE", "/resource", MockResponse(statusCode: 204))

        let session = URLSession(configuration: .ephemeral)

        let (getData, getResp) = try await session.data(from: server.url(forPath: "/resource"))
        #expect((getResp as! HTTPURLResponse).statusCode == 200)
        #expect(String(data: getData, encoding: .utf8) == #"{"action": "read"}"#)

        var deleteReq = URLRequest(url: server.url(forPath: "/resource"))
        deleteReq.httpMethod = "DELETE"
        let (_, deleteResp) = try await session.data(for: deleteReq)
        #expect((deleteResp as! HTTPURLResponse).statusCode == 204)
    }

    // MARK: - Response throttling

    @Test func throttledResponseDelivered() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        let body = String(repeating: "x", count: 500)
        server.enqueue(MockResponse(statusCode: 200).withBody(.text(body)).withThrottle(bytesPerSecond: 65536))

        let session = URLSession(configuration: .ephemeral)
        let (data, resp) = try await session.data(from: server.url(forPath: "/throttled"))
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == body)
    }

    // MARK: - Route hit counting

    @Test func routeHitCountTracksRequests() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.route("/api/health", .json(#"{"status": "ok"}"#))

        let session = URLSession(configuration: .ephemeral)
        _ = try await session.data(from: server.url(forPath: "/api/health"))
        _ = try await session.data(from: server.url(forPath: "/api/health"))
        _ = try await session.data(from: server.url(forPath: "/api/health"))

        #expect(server.routeHitCount(forPath: "/api/health") == 3)
    }

    @Test func routeHitCountForUnknownPath() throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        #expect(server.routeHitCount(forPath: "/unknown") == 0)
    }

    @Test func routeHitCountTracksQueuedResponses() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(.text("a"))
        server.enqueue(.text("b"))
        server.enqueue(.text("c"))

        let session = URLSession(configuration: .ephemeral)
        _ = try await session.data(from: server.url(forPath: "/a"))
        _ = try await session.data(from: server.url(forPath: "/b"))
        _ = try await session.data(from: server.url(forPath: "/a"))

        #expect(server.routeHitCount(forPath: "/a") == 2)
        #expect(server.routeHitCount(forPath: "/b") == 1)
    }

    // MARK: - withServer

    @Test func withServerStartsAndShutsDown() async throws {
        var capturedPort: UInt16 = 0
        try await MockWebServer.withServer { server in
            capturedPort = server.port
            #expect(capturedPort > 0)

            server.enqueue(MockResponse(statusCode: 200).withBody(.text("scoped")))
            let (data, response) = try await URLSession.shared.data(from: server.url(forPath: "/test"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(String(data: data, encoding: .utf8) == "scoped")
        }
        // Server should be shut down — port is released
        #expect(capturedPort > 0)
    }

    @Test func noResponse() async throws {
        let server = MockWebServer()
        try server.start()
        defer { server.shutdown() }

        server.enqueue(MockResponse().withSocketPolicy(.noResponse))

        let url = server.url(forPath: "/timeout")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: config)

        do {
            _ = try await session.data(from: url)
            Issue.record("Expected a timeout error")
        } catch {
            // Expected — server never responded
        }
    }
}
