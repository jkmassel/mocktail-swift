import Foundation
import Network

/// A process-wide pool of pre-started `NWListener` instances for plain TCP.
///
/// Creating and destroying `NWListener` objects per-test causes sporadic
/// `startTimedOut` failures on iOS Simulator CI. This pool creates a fixed
/// set of listeners once at process startup. Tests check out a listener,
/// use it, and return it — the listener stays in `.ready` state forever.
final class ListenerPool: @unchecked Sendable {
    struct PooledListener {
        let listener: NWListener
        let port: UInt16
        let queue: DispatchQueue
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
        pooled.listener.newConnectionHandler = { $0.cancel() }
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

        // newConnectionHandler must be set before start() — the Network
        // framework requires it. Set a placeholder that rejects connections;
        // the real handler is installed when a server checks out this listener.
        listener.newConnectionHandler = { $0.cancel() }

        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 10) == .success,
              !failed,
              let port = listener.port?.rawValue
        else {
            listener.cancel()
            return nil
        }

        return PooledListener(listener: listener, port: port, queue: queue)
    }
}
