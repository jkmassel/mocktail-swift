import Foundation
import Network

final class ConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let onRequest: @Sendable (RecordedRequest) -> MockResponse
    private var buffer = Data()

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        onRequest: @escaping @Sendable (RecordedRequest) -> MockResponse
    ) {
        self.connection = connection
        self.onRequest = onRequest
        connection.start(queue: queue)
        startReading()
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: - Private

    private func startReading() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] content, _, isComplete, error in
            if let error {
                _ = error // connection failed
                connection.cancel()
                return
            }

            if let content {
                buffer.append(content)
            }

            if let request = HTTPParser.parseRequest(from: buffer) {
                let response = onRequest(request)
                handleResponse(response)
            } else if isComplete {
                connection.cancel()
            } else {
                startReading()
            }
        }
    }

    private func handleResponse(_ response: MockResponse) {
        switch response.socketPolicy {
        case .disconnectImmediately:
            connection.cancel()
            return
        case .noResponse:
            // Accept but never respond — for timeout testing
            return
        case .keepOpen:
            break
        }

        if let delay = response.bodyDelay {
            let (seconds, attoseconds) = delay.components
            let interval = Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [self] in
                sendResponse(response)
            }
        } else {
            sendResponse(response)
        }
    }

    private func sendResponse(_ response: MockResponse) {
        let data = HTTPParser.serializeResponse(response)

        guard let rate = response.throttleRate, rate > 0 else {
            connection.send(content: data, completion: .contentProcessed { [self] _ in
                connection.cancel()
            })
            return
        }

        sendThrottled(data: data, offset: 0, bytesPerSecond: rate)
    }

    private func sendThrottled(data: Data, offset: Int, bytesPerSecond: Int) {
        guard offset < data.count else {
            connection.cancel()
            return
        }

        let chunkSize = max(bytesPerSecond, 1)
        let end = min(offset + chunkSize, data.count)
        let chunk = data[offset..<end]

        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            guard error == nil else {
                connection.cancel()
                return
            }

            if end >= data.count {
                connection.cancel()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [self] in
                    sendThrottled(data: data, offset: end, bytesPerSecond: bytesPerSecond)
                }
            }
        })
    }
}
