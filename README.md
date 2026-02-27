# MockWebServer

A real TCP-listening HTTP/HTTPS mock server for Swift tests. Inspired by OkHttp's [MockWebServer](https://github.com/square/okhttp/tree/master/mockwebserver).

Unlike URL protocol stubs that intercept requests before they hit the network, MockWebServer opens a real socket on localhost. This means you can test scenarios that require actual TCP connections: TLS handshake failures, expired certificates, connection drops, and timeouts.

[API Documentation](https://jkmassel.github.io/mocktail-swift/documentation/mockwebserver)

## Requirements

- macOS 13+ / iOS 16+
- Swift 6.0+
- No external dependencies

## Installation

Add MockWebServer to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jkmassel/mocktail-swift.git", branch: "main"),
],
targets: [
    .testTarget(
        name: "YourTests",
        dependencies: [
            .product(name: "MockWebServer", package: "mocktail-swift"),
        ]
    ),
]
```

## Quick Start

```swift
import Testing
import MockWebServer

@Test func fetchGreeting() async throws {
    try await MockWebServer.withServer { server in
        server.enqueue(MockResponse(statusCode: 200).withBody("Hello!"))

        let url = server.url(forPath: "/greeting")
        let (data, response) = try await URLSession.shared.data(from: url)

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "Hello!")
    }
}
```

The server starts automatically and shuts down when the closure returns. You can also manage the lifecycle manually:

```swift
let server = MockWebServer()
try server.start()
defer { server.shutdown() }
```

## Usage

### Enqueue responses

Enqueued responses are consumed in order, one per request. This lets the same endpoint return different results over time — useful for simulating state changes:

```swift
// GET /users → one user, POST /users → created, GET /users → two users
server.enqueue(.json(#"[{"id": 1}]"#))
server.enqueue(.json(#"{"id": 2}"#, statusCode: 201))
server.enqueue(.json(#"[{"id": 1}, {"id": 2}]"#))
```

See [BasicHTTPTests.swift](Examples/BasicHTTPTests.swift) for runnable examples.

### Static content helpers

Use `.json()`, `.html()`, and `.text()` to create responses with the correct Content-Type header:

```swift
server.enqueue(.json(#"{"id": 1, "name": "Alice"}"#))
server.enqueue(.json(#"{"error": "not found"}"#, statusCode: 404))
server.enqueue(.html("<h1>Hello</h1>"))
server.enqueue(.text("plain text body"))
```

Load response bodies from fixture files in your test bundle. Content-Type is inferred from the file extension:

```swift
// Loads "Fixtures/users.json" from your test target's bundle
server.enqueue(try .fromResource("users", extension: "json", in: .module))
server.enqueue(try .fromResource("page", extension: "html", in: .module))

// Override the content type if needed
server.enqueue(try .fromResource("feed", extension: "xml", in: .module, contentType: "application/atom+xml"))
```

### Path-based routing

Use `route()` to register persistent responses for specific paths. Unlike `enqueue()`, routes are never consumed and serve every matching request. Routes take priority over the FIFO queue.

```swift
server.route("/", .html("<h1>Welcome</h1>"))
server.route("/api/status", .json(#"{"status": "ok", "version": "2.1"}"#))
server.route("/api/users", .json(#"[{"id": 1, "name": "Alice"}]"#))

// Each route serves the same response every time
let (home1, _) = try await session.data(from: server.url(forPath: "/"))
let (home2, _) = try await session.data(from: server.url(forPath: "/"))
// Both return "<h1>Welcome</h1>"
```

You can also register routes for specific HTTP methods. Method-specific routes take priority over catch-all routes:

```swift
server.route("GET", "/api/users", .json(#"[{"id": 1}]"#))
server.route("POST", "/api/users", .json(#"{"id": 2}"#, statusCode: 201))
server.route("/api/users", .json(#"{"fallback": true}"#))  // catch-all for other methods

// GET /api/users  → [{"id": 1}]       (method-specific)
// POST /api/users → {"id": 2}         (method-specific)
// PUT /api/users  → {"fallback": true} (catch-all)
```

You can combine routes with the FIFO queue. Routes are checked first; unmatched paths fall back to the queue:

```swift
server.route("/api/config", .json(#"{"version": 2}"#))
server.enqueue(.json(#"{"fallback": true}"#))

// GET /api/config → returns the routed response (persistent)
// GET /anything-else → returns the queued response (consumed)
```

See [BasicHTTPTests.swift](Examples/BasicHTTPTests.swift) and [MethodRoutingTests.swift](Examples/MethodRoutingTests.swift) for runnable examples.

### Dynamic routes

Routes can also accept closures for dynamic response handling. The closure receives the full `RecordedRequest`:

```swift
server.route("/api/users") { request in
    .json(#"{"path": "\(request.path)"}"#)
}

server.route("POST", "/api/users") { request in
    .json(#"{"created": true}"#, statusCode: 201)
}
```

See [ClosureRouteTests.swift](Examples/ClosureRouteTests.swift) for runnable examples.

### Route hit counting

Track how many times each path has been requested:

```swift
server.route("/api/health", .json(#"{"status": "ok"}"#))

// ... make requests ...

#expect(server.routeHitCount(forPath: "/api/health") == 3)
#expect(server.routeHitCount(forPath: "/unknown") == 0)
```

Hit counts track all requests, regardless of whether they were handled by a route or the queue. See [BasicHTTPTests.swift](Examples/BasicHTTPTests.swift) for a runnable example.

### Redirects

Since MockWebServer is a real server, URLSession follows redirects automatically. Use `enqueueRedirect(to:then:)` to set up a redirect and its final response in one call:

```swift
server.enqueueRedirect(
    to: "/api/v2/users.json",
    then: MockResponse(statusCode: 200)
        .withBody(#"{"users": [{"id": 1, "name": "Alice"}]}"#)
        .withHeader("Content-Type", "application/json")
)

let (data, response) = try await session.data(from: server.url(forPath: "/api/v1/users"))
// URLSession followed the redirect -- you get the JSON directly
#expect((response as! HTTPURLResponse).statusCode == 200)
```

Specify the redirect type with the `RedirectType` enum:

```swift
server.enqueueRedirect(to: "/new-location", type: .permanent, then: .json("{}"))
server.enqueueRedirect(to: "/new-location", type: .temporaryPreservingMethod, then: .json("{}"))
```

You can also use `MockResponse.redirect(to:)` directly if you need more control (e.g., chaining multiple redirects):

```swift
server.enqueue(.redirect(to: "/step2", type: .permanent))
server.enqueue(.redirect(to: "/step3"))
server.enqueue(MockResponse(statusCode: 200).withBody("final"))
```

### Verify requests

Use `takeRequest()` to inspect what your code actually sent. Requests are recorded in order.

```swift
server.enqueue(MockResponse(statusCode: 200))

// ... your code makes a request ...

let recorded = await server.takeRequest()
#expect(recorded?.method == "POST")
#expect(recorded?.path == "/api/posts")
#expect(recorded?.body == Data(#"{"title":"Hello"}"#.utf8))

let authHeader = recorded?.headers.first { $0.0 == "Authorization" }
#expect(authHeader?.1 == "Bearer my-token")
```

`takeRequest()` waits asynchronously for a request to arrive. It returns `nil` after the timeout (default 5 seconds):

```swift
let result = await server.takeRequest(timeout: .milliseconds(500))
#expect(result == nil) // no request arrived
```

See [RequestVerificationTests.swift](Examples/RequestVerificationTests.swift) for runnable examples.

### Simulate network issues

Use socket policies to test error handling:

```swift
// Server accepts connection but never responds (timeout testing)
server.enqueue(MockResponse().withSocketPolicy(.noResponse))

// Server accepts connection then immediately closes it
server.enqueue(MockResponse().withSocketPolicy(.disconnectImmediately))

// Server responds after a delay
server.enqueue(
    MockResponse(statusCode: 200)
        .withBody("slow")
        .withBodyDelay(.seconds(2))
)
```

### Response throttling

Simulate a slow network connection by throttling the response. The body is sent in chunks at the specified bytes-per-second rate:

```swift
server.enqueue(
    MockResponse(statusCode: 200)
        .withBody(largePayload)
        .withThrottle(bytesPerSecond: 1024)
)
```

Throttling composes with body delay -- the delay fires first, then the response trickles out:

```swift
server.enqueue(
    MockResponse(statusCode: 200)
        .withBody(data)
        .withBodyDelay(.seconds(1))        // 1 second think time
        .withThrottle(bytesPerSecond: 512)  // then slow delivery
)
```

See [SocketPolicyTests.swift](Examples/SocketPolicyTests.swift) for runnable examples of socket policies and throttling.

### HTTPS and TLS testing

Start the server with a `TLSConfiguration` to enable HTTPS. The package includes pre-generated certificates for common test scenarios:

```swift
// Self-signed cert for localhost (valid 10 years)
let tls = try TLSConfiguration.localhost()
try server.start(tls: tls)

// URLSession will reject self-signed certs by default.
// Use a delegate that trusts all certs for testing:
let delegate = TrustAllDelegate()
let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
let (data, _) = try await session.data(from: server.url(forPath: "/secure"))
```

Test certificate validation errors:

```swift
// Expired certificate -- URLSession should reject it
let expired = try TLSConfiguration.expired()
try server.start(tls: expired)

// Wrong hostname -- cert is for "wrong.example.com", not "127.0.0.1"
let wrongHost = try TLSConfiguration.wrongHostname()
try server.start(tls: wrongHost)
```

Test HTTPS-to-HTTP mismatch:

```swift
try server.start() // plain HTTP
let httpsURL = URL(string: "https://127.0.0.1:\(server.port)/path")!
// URLSession TLS handshake fails against plain TCP
```

You can also load your own `.p12` certificate:

```swift
let p12Data = try Data(contentsOf: URL(fileURLWithPath: "my-cert.p12"))
let tls = try TLSConfiguration(p12Data: p12Data, password: "my-password")
try server.start(tls: tls)
```

See [TLSExamples.swift](Examples/TLSExamples.swift) for runnable examples.

## Examples

See the [`Examples/`](Examples/) directory for complete, copy-paste-ready test files (compiled and run in CI):

- **[BasicHTTPTests.swift](Examples/BasicHTTPTests.swift)** -- GET/POST requests, path-based routing, redirects, hit counting, error codes
- **[ClosureRouteTests.swift](Examples/ClosureRouteTests.swift)** -- Dynamic request handling with closure routes
- **[MethodRoutingTests.swift](Examples/MethodRoutingTests.swift)** -- REST-style GET/POST/DELETE on the same path
- **[RequestVerificationTests.swift](Examples/RequestVerificationTests.swift)** -- Inspecting headers, verifying call order, async waiting
- **[SocketPolicyTests.swift](Examples/SocketPolicyTests.swift)** -- Timeouts, connection drops, throttling, slow responses
- **[TLSExamples.swift](Examples/TLSExamples.swift)** -- HTTPS, expired certs, wrong hostname, protocol mismatch

## Regenerating Certificates

The bundled `.p12` files are pre-generated and committed to the repo. To regenerate them:

```bash
./scripts/generate-certs.sh
```

Requires OpenSSL 3.x. All certificates use the password `test`.

## License

See [LICENSE](LICENSE) for details.
