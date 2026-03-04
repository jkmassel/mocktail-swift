import Foundation
import Network

/// Errors thrown by ``MockWebServer/start(tls:)``.
public enum MockWebServerError: Error {
    /// The server's network listener failed to start.
    case startFailed(NWError)
    /// The server did not become ready within the startup timeout.
    case startTimedOut
}

/// A real TCP-listening HTTP/HTTPS mock server for Swift tests.
///
/// Unlike URL protocol stubs that intercept requests before they hit the network,
/// `MockWebServer` opens a real socket on localhost. This lets you test scenarios
/// that require actual TCP connections: TLS handshake failures, expired certificates,
/// connection drops, timeouts, and rate limiting.
///
/// Routes handle matching requests; unmatched requests consume the next enqueued response.
public final class MockWebServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var responseQueue: [MockResponse] = []
    private var methodRoutes: [String: [String: @Sendable (RecordedRequest) -> MockResponse]] = [:]
    private var catchAllRoutes: [String: @Sendable (RecordedRequest) -> MockResponse] = [:]
    private var hitCounts: [String: Int] = [:]
    private var recordedRequests: [RecordedRequest] = []
    private var requestWaiters: [(id: UUID, continuation: CheckedContinuation<RecordedRequest?, Never>)] = []
    private var handlers: [ConnectionHandler] = []
    private let dispatchQueue = DispatchQueue(label: "com.mockwebserver")
    private var _port: UInt16 = 0
    private var useTLS = false
    private var pooledListener: ListenerPool.PooledListener?

    public init() {}

    /// Runs the given closure with a started server, shutting it down automatically when the closure returns.
    ///
    /// This is the recommended way to use `MockWebServer` in tests:
    /// ```swift
    /// try await MockWebServer.withServer { server in
    ///     server.enqueue(.json("{}"))
    ///     let (data, _) = try await URLSession.shared.data(from: server.url(forPath: "/test"))
    /// }
    /// ```
    @discardableResult
    public static func withServer<T: Sendable>(
        tls: TLSConfiguration? = nil,
        _ body: (MockWebServer) async throws -> T
    ) async throws -> T {
        let server = MockWebServer()
        try await server.start(tls: tls)
        defer { server.shutdown() }
        return try await body(server)
    }

    /// The port the server is listening on, or `0` if not started.
    public var port: UInt16 {
        lock.withLock { _port }
    }

    public var requestCount: Int {
        lock.withLock { recordedRequests.count }
    }

    /// Start listening on a random available port.
    ///
    /// Prefer the async overload ``start(tls:)-async`` when calling from
    /// an `async` context (e.g. Swift Testing `@Test` functions) to avoid
    /// blocking a cooperative thread.
    ///
    /// - Returns: `self`, so you can write `let server = try MockWebServer().start()`.
    /// - Throws: ``MockWebServerError`` if the listener fails to start or times out.
    @discardableResult
    public func start(tls: TLSConfiguration? = nil) throws -> MockWebServer {
        if let tls {
            let listener = try startListener(params: tls.parameters)
            configureAfterStart(listener: listener, tls: tls)
        } else {
            let pooled = ListenerPool.shared.checkout()
            configurePooledListener(pooled)
        }
        return self
    }

    /// Start listening on a random available port (async version).
    ///
    /// This overload moves blocking work off the Swift Concurrency cooperative
    /// thread pool, preventing deadlocks when many async tests start servers
    /// concurrently.
    ///
    /// - Returns: `self`, so you can write `let server = try await MockWebServer().start()`.
    /// - Throws: ``MockWebServerError`` if the listener fails to start or times out.
    @discardableResult
    public func start(tls: TLSConfiguration? = nil) async throws -> MockWebServer {
        if let tls {
            let listener = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWListener, any Error>) in
                DispatchQueue.global().async {
                    do {
                        let listener = try self.startListener(params: tls.parameters)
                        continuation.resume(returning: listener)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            configureAfterStart(listener: listener, tls: tls)
        } else {
            let pooled = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let pooled = ListenerPool.shared.checkout()
                    continuation.resume(returning: pooled)
                }
            }
            configurePooledListener(pooled)
        }
        return self
    }

    /// Start a per-test NWListener for TLS. Only used when a `TLSConfiguration`
    /// is provided — plain TCP uses the shared ``ListenerPool``.
    private func startListener(params: NWParameters) throws -> NWListener {
        let listener = try NWListener(using: params, on: .any)

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var startError: NWError?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startError = error
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: dispatchQueue)

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            listener.cancel()
            throw MockWebServerError.startTimedOut
        }

        if let error = startError {
            throw MockWebServerError.startFailed(error)
        }

        return listener
    }

    private func configureAfterStart(listener: NWListener, tls: TLSConfiguration?) {
        lock.withLock {
            self.listener = listener
            self._port = listener.port?.rawValue ?? 0
            self.useTLS = tls != nil
        }
    }

    private func configurePooledListener(_ pooled: ListenerPool.PooledListener) {
        pooled.listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        lock.withLock {
            self.pooledListener = pooled
            self.listener = pooled.listener
            self._port = pooled.port
        }
    }

    /// Add a response that will be returned for the next unmatched request.
    ///
    /// Enqueued responses are consumed in order, one per request. If no responses
    /// remain and no route matches, the server returns a 500.
    public func enqueue(_ response: MockResponse) {
        lock.withLock { responseQueue.append(response) }
    }

    /// Register a persistent response for a path, matching any HTTP method.
    ///
    /// Unlike enqueued responses, routes are never consumed and serve every matching request.
    public func route(_ path: String, _ response: MockResponse) {
        route(path) { _ in response }
    }

    /// Register a persistent closure for a path, matching any HTTP method.
    ///
    /// The closure receives the full ``RecordedRequest`` and can return a dynamic response.
    /// It may safely call back into the server (e.g. ``routeHitCount(forPath:)``).
    public func route(_ path: String, _ handler: @escaping @Sendable (RecordedRequest) -> MockResponse) {
        lock.withLock { catchAllRoutes[path] = handler }
    }

    /// Register a persistent response for a specific HTTP method and path.
    ///
    /// The method match is case-insensitive. Method-specific routes take priority
    /// over catch-all routes.
    public func route(_ method: String, _ path: String, _ response: MockResponse) {
        route(method, path) { _ in response }
    }

    /// Register a persistent closure for a specific HTTP method and path.
    ///
    /// The method match is case-insensitive. Method-specific routes take priority
    /// over catch-all routes.
    /// The closure receives the full ``RecordedRequest`` and can return a dynamic response.
    /// It may safely call back into the server (e.g. ``routeHitCount(forPath:)``).
    public func route(_ method: String, _ path: String, _ handler: @escaping @Sendable (RecordedRequest) -> MockResponse) {
        lock.withLock {
            var pathRoutes = methodRoutes[path, default: [:]]
            pathRoutes[method.uppercased()] = handler
            methodRoutes[path] = pathRoutes
        }
    }

    /// Returns the number of times the given path has been requested.
    public func routeHitCount(forPath path: String) -> Int {
        lock.withLock { hitCounts[path, default: 0] }
    }

    /// Enqueue a redirect followed by its final response.
    ///
    /// `URLSession` follows the redirect automatically, so the caller receives `then` directly.
    public func enqueueRedirect(to path: String, type: RedirectType = .temporary, then response: MockResponse) {
        enqueueAll(.redirect(to: path, type: type), response)
    }

    /// Enqueue a 429 rate-limited response followed by a subsequent response.
    ///
    /// This is a convenience that enqueues two responses atomically: a 429 with the given
    /// `Retry-After` header, then `response`. Your client code is responsible for
    /// reading the `Retry-After` header and retrying — `URLSession` does not
    /// retry 429s automatically (unlike redirects).
    public func enqueueRateLimited(retryAfter: UInt, body: ResponseBody = .text("Too Many Requests"), then response: MockResponse) {
        enqueueAll(.rateLimited(retryAfter: retryAfter, body: body), response)
    }

    private func enqueueAll(_ responses: MockResponse...) {
        lock.withLock { responseQueue.append(contentsOf: responses) }
    }

    /// Returns a URL for the given path on this server (e.g. `http://127.0.0.1:{port}/path`).
    ///
    /// The scheme is `https` if the server was started with a ``TLSConfiguration``, otherwise `http`.
    public func url(forPath path: String) -> URL {
        let (scheme, currentPort) = lock.withLock { (useTLS ? "https" : "http", _port) }
        return URL(string: "\(scheme)://127.0.0.1:\(currentPort)\(path)")!
    }

    /// Wait for and return the next recorded request.
    ///
    /// Requests are recorded in the order they arrive. Returns `nil` if no request
    /// arrives before the timeout expires.
    /// - Parameter timeout: How long to wait. Defaults to 5 seconds.
    public func takeRequest(timeout: Duration = .seconds(5)) async -> RecordedRequest? {
        let id = UUID()

        return await withCheckedContinuation { continuation in
            lock.lock()
            if !recordedRequests.isEmpty {
                let request = recordedRequests.removeFirst()
                lock.unlock()
                continuation.resume(returning: request)
                return
            }
            requestWaiters.append((id: id, continuation: continuation))
            lock.unlock()

            let (seconds, attoseconds) = timeout.components
            let interval = Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let index = self.requestWaiters.firstIndex(where: { $0.id == id }) {
                    let waiter = self.requestWaiters.remove(at: index)
                    self.lock.unlock()
                    waiter.continuation.resume(returning: nil)
                } else {
                    self.lock.unlock()
                }
            }
        }
    }

    /// Stop the server and close all connections.
    ///
    /// Clears all enqueued responses, routes, and recorded requests.
    /// Any pending ``takeRequest(timeout:)`` calls will return `nil`.
    public func shutdown() {
        lock.lock()
        let currentPooled = pooledListener
        let currentListener = listener
        let currentHandlers = handlers
        let currentWaiters = requestWaiters
        pooledListener = nil
        listener = nil
        handlers = []
        requestWaiters = []
        responseQueue = []
        methodRoutes = [:]
        catchAllRoutes = [:]
        hitCounts = [:]
        recordedRequests = []
        _port = 0
        useTLS = false
        lock.unlock()

        // Immediately reject new connections before cancelling handlers.
        // This prevents stray requests from a previous borrower's URLSession
        // from being routed to the next borrower after the listener is returned
        // to the pool.
        currentPooled?.listener.newConnectionHandler = { $0.cancel() }

        for waiter in currentWaiters {
            waiter.continuation.resume(returning: nil)
        }
        for handler in currentHandlers {
            handler.cancel()
        }

        if let currentPooled {
            ListenerPool.shared.checkin(currentPooled)
        } else {
            currentListener?.cancel()
        }
    }

    deinit {
        // Cancel without resuming waiters (they'll be deallocated)
        lock.lock()
        let currentPooled = pooledListener
        let currentListener = listener
        let currentHandlers = handlers
        pooledListener = nil
        listener = nil
        handlers = []
        lock.unlock()

        currentPooled?.listener.newConnectionHandler = { $0.cancel() }

        for handler in currentHandlers {
            handler.cancel()
        }

        if let currentPooled {
            ListenerPool.shared.checkin(currentPooled)
        } else {
            currentListener?.cancel()
        }
    }

    // MARK: - Private

    private func handleNewConnection(_ connection: NWConnection) {
        // Check if the next response requires early connection handling
        let nextPolicy: SocketPolicy? = lock.withLock { responseQueue.first?.socketPolicy }

        if nextPolicy == .disconnectImmediately {
            _ = lock.withLock { responseQueue.isEmpty ? nil : responseQueue.removeFirst() }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.forceCancel()
                }
            }
            connection.start(queue: dispatchQueue)
            return
        }

        let handler = ConnectionHandler(
            connection: connection,
            queue: dispatchQueue
        ) { [weak self] request in
            guard let self else { return MockResponse(statusCode: 500) }
            self.recordRequest(request)
            return self.responseFor(request: request)
        }

        lock.withLock {
            handlers.append(handler)
        }
    }

    private func responseFor(request: RecordedRequest) -> MockResponse {
        // Copy the route handler and increment hit count while holding the lock,
        // then call the handler outside the lock so it can safely call back
        // into the server (e.g. enqueue, routeHitCount) without deadlocking.
        let handler: (@Sendable (RecordedRequest) -> MockResponse)? = lock.withLock {
            hitCounts[request.path, default: 0] += 1

            // 1. Check method-specific routes
            if let pathRoutes = methodRoutes[request.path],
               let matched = pathRoutes[request.method.uppercased()] {
                return matched
            }
            // 2. Check catch-all routes
            if let matched = catchAllRoutes[request.path] {
                return matched
            }
            return nil
        }

        // Call matched route handler outside the lock
        if let handler {
            return handler(request)
        }

        // 3. Fall back to queue (lock-protected, consumed on use)
        return lock.withLock {
            if responseQueue.isEmpty {
                return MockResponse(statusCode: 500)
            }
            return responseQueue.removeFirst()
        }
    }

    private func recordRequest(_ request: RecordedRequest) {
        lock.lock()
        if !requestWaiters.isEmpty {
            let waiter = requestWaiters.removeFirst()
            lock.unlock()
            waiter.continuation.resume(returning: request)
        } else {
            recordedRequests.append(request)
            lock.unlock()
        }
    }
}
