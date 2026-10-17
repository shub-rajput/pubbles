import Foundation

/// Minimal synchronous Chrome DevTools Protocol client over a websocket.
final class CDP {
    private let task: URLSessionWebSocketTask
    private var nextId = 1

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        task.resume()
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], timeout: Double = 15) throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let sent = DispatchSemaphore(value: 0)
        var sendError: Error?
        task.send(.string(String(decoding: payload, as: UTF8.self))) { error in
            sendError = error
            sent.signal()
        }
        sent.wait()
        if let sendError { throw DriverError.cdp("\(method): \(sendError.localizedDescription)") }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try receive(timeout: deadline.timeIntervalSinceNow)
            guard (message["id"] as? Int) == id else { continue } // skip events
            if let error = message["error"] as? [String: Any] {
                throw DriverError.cdp("\(method): \(error["message"] ?? error)")
            }
            return message["result"] as? [String: Any] ?? [:]
        }
        throw DriverError.cdp("\(method) timed out")
    }

    /// Evaluate JS in the page and return its JSON value. Awaits promises by default.
    @discardableResult
    func eval(_ js: String, awaitPromise: Bool = true) throws -> Any? {
        let result = try call("Runtime.evaluate", [
            "expression": js,
            "returnByValue": true,
            "awaitPromise": awaitPromise,
        ])
        if let ex = result["exceptionDetails"] as? [String: Any] {
            let desc = ((ex["exception"] as? [String: Any])?["description"] as? String) ?? "\(ex["text"] ?? ex)"
            throw DriverError.cdp("JS error: \(desc)")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func receive(timeout: Double) throws -> [String: Any] {
        let got = DispatchSemaphore(value: 0)
        var outcome: Result<URLSessionWebSocketTask.Message, Error>?
        task.receive { result in
            outcome = result
            got.signal()
        }
        guard got.wait(timeout: .now() + max(0.05, timeout)) == .success, let outcome else {
            throw DriverError.cdp("websocket receive timed out")
        }
        switch outcome {
        case .failure(let error):
            throw DriverError.cdp("websocket: \(error.localizedDescription)")
        case .success(.string(let text)):
            return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        case .success(.data(let data)):
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case .success:
            return [:]
        }
    }

    /// GET a JSON document from Chrome's HTTP debug endpoint.
    static func getJSON(_ url: URL, timeout: Double = 2) -> Any? {
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, _, _ in
            body = data
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 0.5)
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body)
    }
}
