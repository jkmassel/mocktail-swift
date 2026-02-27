# ``MockWebServer``

A real TCP-listening HTTP/HTTPS mock server for Swift tests.

## Overview

Unlike URL protocol stubs that intercept requests before they hit the network,
MockWebServer opens a real socket on localhost. This lets you test scenarios
that require actual TCP connections: TLS handshake failures, expired certificates,
connection drops, and timeouts.

```swift
@Test func fetchGreeting() async throws {
    try await MockWebServer.withServer { server in
        server.enqueue(.json(#"{"message": "hello"}"#))

        let url = server.url(forPath: "/greeting")
        let (data, _) = try await URLSession.shared.data(from: url)
        #expect(String(data: data, encoding: .utf8)!.contains("hello"))
    }
}
```

Routes handle matching requests; unmatched requests consume the next enqueued response.

## Topics

### Server Lifecycle

- ``MockWebServer/withServer(tls:_:)``
- ``MockWebServer/init()``
- ``MockWebServer/start(tls:)``
- ``MockWebServer/shutdown()``
- ``MockWebServer/port``
- ``MockWebServer/url(forPath:)``
- ``MockWebServerError``

### Configuring Responses

- ``MockResponse``
- ``MockWebServer/enqueue(_:)``
- ``MockWebServer/enqueueRedirect(to:type:then:)``
- ``MockWebServer/route(_:_:)-(_,MockResponse)``
- ``MockWebServer/route(_:_:_:)-(_,_,MockResponse)``
- ``SocketPolicy``
- ``RedirectType``
- ``MockResponseError``

### Request Verification

- ``RecordedRequest``
- ``MockWebServer/takeRequest(timeout:)``
- ``MockWebServer/requestCount``
- ``MockWebServer/routeHitCount(forPath:)``

### TLS

- ``TLSConfiguration``
- ``TLSError``
- ``CertificateStore``
- ``CertificateStoreError``
