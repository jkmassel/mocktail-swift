import Foundation

enum HTTPParser {

    // MARK: - Request Parsing

    static func parseRequest(from data: Data) -> RecordedRequest? {
        let bytes = Array(data)

        guard let headerEnd = findHeaderEnd(in: bytes) else { return nil }

        let headerData = Data(bytes[0..<headerEnd])
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [(String, String)] = []
        var contentLength = 0
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            if name.lowercased() == "content-length", let length = Int(value) {
                contentLength = length
            }
        }

        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        let availableBody = bytes.count - bodyStart

        if availableBody < contentLength {
            return nil // need more data
        }

        let body: Data?
        if contentLength > 0 {
            body = Data(bytes[bodyStart..<(bodyStart + contentLength)])
        } else {
            body = nil
        }

        return RecordedRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Response Serialization

    static func serializeResponse(_ response: MockResponse) -> Data {
        var headerString = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"

        var headers = response.headers

        if let body = response.body {
            if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
                headers.append(("Content-Length", "\(body.count)"))
            }
        } else {
            if !headers.contains(where: { $0.0.lowercased() == "content-length" }) {
                headers.append(("Content-Length", "0"))
            }
        }

        if !headers.contains(where: { $0.0.lowercased() == "connection" }) {
            headers.append(("Connection", "close"))
        }

        for (name, value) in headers {
            headerString += "\(name): \(value)\r\n"
        }
        headerString += "\r\n"

        var data = Data(headerString.utf8)
        if let body = response.body {
            data.append(body)
        }
        return data
    }

    // MARK: - Private

    private static func findHeaderEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 0x0D && bytes[i + 1] == 0x0A
                && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A
            {
                return i
            }
        }
        return nil
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}
