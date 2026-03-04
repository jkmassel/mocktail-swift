import Foundation
import Network

/// A process-wide pool of pre-started `NWListener` instances for plain TCP.
///
/// Creating and destroying `NWListener` objects per-test causes sporadic
/// `startTimedOut` failures on iOS Simulator CI. This pool creates a fixed
/// set of listeners once at process startup. Tests check out a listener,
/// use it, and return it — the listener stays in `.ready` state forever.
final class ListenerPool: @unchecked Sendable {
    /// A pooled listener whose `newConnectionHandler` is set once before `start()`
    /// and never reassigned. The permanent handler delegates to `connectionHandler`,
    /// which borrowers swap in/out without touching the NWListener directly.
    final class PooledListener: @unchecked Sendable {
        let listener: NWListener
        fileprivate(set) var port: UInt16
        let queue: DispatchQueue

        private let lock = NSLock()
        private var _connectionHandler: (@Sendable (NWConnection) -> Void)?

        /// The active connection handler. Set by the borrowing server on checkout;
        /// cleared on checkin. When `nil`, incoming connections are cancelled.
        var connectionHandler: (@Sendable (NWConnection) -> Void)? {
            get { lock.withLock { _connectionHandler } }
            set { lock.withLock { _connectionHandler = newValue } }
        }

        init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
            self.listener = listener
            self.port = port
            self.queue = queue
        }
    }

    static let shared = ListenerPool()

    private let lock = NSLock()
    private var available: [PooledListener] = []
    private let semaphore: DispatchSemaphore

    private init() {
        let poolSize = 6
        var created: [PooledListener] = []

        for i in 0..<poolSize {
            // Each listener gets its own queue to avoid serialization during init.
            let queue = DispatchQueue(label: "com.mockwebserver.pool.\(i)")

            guard let pooled = Self.createListener(queue: queue) else {
                continue
            }
            created.append(pooled)
        }

        precondition(!created.isEmpty, "ListenerPool: failed to create any NWListeners")
        available = created
        semaphore = DispatchSemaphore(value: created.count)
    }

    func checkout() -> PooledListener {
        semaphore.wait()
        return lock.withLock { available.removeFirst() }
    }

    func checkin(_ pooled: PooledListener) {
        pooled.connectionHandler = nil
        lock.withLock { available.append(pooled) }
        semaphore.signal()
    }

    // MARK: - Private

    private static func createListener(queue: DispatchQueue) -> PooledListener? {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            return nil
        }

        let readySemaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failed = false

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case .failed:
                failed = true
                readySemaphore.signal()
            default:
                break
            }
        }

        // Create the PooledListener first so the permanent newConnectionHandler
        // can capture it. The handler is set once before start() (as the Network
        // framework requires) and never reassigned — it delegates to the mutable
        // connectionHandler property, which borrowers swap in/out.
        let pooled = PooledListener(listener: listener, port: 0, queue: queue)

        listener.newConnectionHandler = { [weak pooled] connection in
            if let handler = pooled?.connectionHandler {
                handler(connection)
            } else {
                connection.cancel()
            }
        }

        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 10) == .success,
              !failed,
              let port = listener.port?.rawValue
        else {
            listener.cancel()
            return nil
        }

        pooled.port = port
        return pooled
    }
}
