import Foundation

enum TakeError: LocalizedError {
    case devTools(String)
    case target(String)
    case script(String)
    case setup(String)
    /// The stage couldn't be made visible, or stopped being usable mid-take. `code` is for agents.
    case stage(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .devTools(let m): return "Stage: \(m)"
        case .target(let t): return "Not on the page: \(t)"
        case .script(let m): return m
        case .setup(let m): return m
        case .stage(_, let m): return m
        }
    }

    var code: String? {
        if case .stage(let code, _) = self { return code }
        return nil
    }
}

/// Minimal Chrome DevTools Protocol client over a websocket. Replies are matched to calls by id;
/// events are ignored.
@MainActor
final class DevTools {
    private let task: URLSessionWebSocketTask
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var receiving: Task<Void, Never>?

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 << 20
        task.resume()
        receiving = Task { [weak self] in await self?.receiveLoop() }
    }

    func close() {
        receiving?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        failAll(TakeError.devTools("connection closed"))
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], timeout: Double = 15) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let message = String(decoding: payload, as: UTF8.self)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            task.send(.string(message)) { error in
                guard let error else { return }
                Task { @MainActor in self.finish(id, .failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                self.finish(id, .failure(TakeError.devTools("\(method) timed out")))
            }
        }
        let reply = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let error = reply["error"] as? [String: Any] {
            throw TakeError.devTools("\(method): \(error["message"] ?? error)")
        }
        return reply["result"] as? [String: Any] ?? [:]
    }

    /// Evaluate JS in the page and return its JSON value.
    @discardableResult
    func eval(_ js: String, awaitPromise: Bool = true) async throws -> Any? {
        let result = try await call("Runtime.evaluate", ["expression": js, "returnByValue": true, "awaitPromise": awaitPromise])
        if let ex = result["exceptionDetails"] as? [String: Any] {
            let desc = ((ex["exception"] as? [String: Any])?["description"] as? String) ?? "\(ex["text"] ?? ex)"
            throw TakeError.devTools("JS error: \(desc)")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let data: Data
                switch try await task.receive() {
                case .string(let text): data = Data(text.utf8)
                case .data(let raw): data = raw
                @unknown default: continue
                }
                guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = message["id"] as? Int else { continue } // events
                finish(id, .success(data))
            } catch {
                failAll(error)
                return
            }
        }
    }

    private func finish(_ id: Int, _ result: Result<Data, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    /// GET a JSON document from Chrome's HTTP debug endpoint.
    static func getJSON(_ url: URL, timeout: Double = 2) async -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
