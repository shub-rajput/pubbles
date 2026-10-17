import AppKit
import Network

/// Pubbles' MCP server: the Streamable HTTP transport on 127.0.0.1, answering each JSON-RPC POST with
/// a single JSON response. Requests need the bearer token; browser origins other than localhost are
/// refused. It only listens while agent access is on.
@MainActor
final class MCPServer {
    static let port: UInt16 = 47817
    static var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    /// Generated once and kept in user defaults; part of the setup line agents are configured with.
    static var token: String {
        if let existing = UserDefaults.standard.string(forKey: "agentToken") { return existing }
        let fresh = (0..<32).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
        UserDefaults.standard.set(fresh, forKey: "agentToken")
        return fresh
    }

    static var claudeAddArguments: [String] {
        ["mcp", "add", "--transport", "http", "--scope", "user", "pubbles", endpoint,
         "--header", "Authorization: Bearer \(token)"]
    }

    static var claudeAddCommand: String {
        "claude mcp add --transport http --scope user pubbles \(endpoint) --header \"Authorization: Bearer \(token)\""
    }

    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let tools: AgentTools
    private var listener: NWListener?
    private(set) var problem: String?

    var isListening: Bool { listener != nil }

    init(tools: AgentTools) {
        self.tools = tools
    }

    func start() {
        guard listener == nil else { return }
        problem = nil
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .failed(let error) = state {
                        self?.problem = "Couldn't listen on port \(Self.port): \(error)"
                        self?.stop()
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "Couldn't start the agent server: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let (request, rest) = HTTPRequest.parse(buffer) {
                    Task { @MainActor in
                        let response = await self.respond(to: request)
                        connection.send(content: response.serialized, completion: .contentProcessed { _ in
                            if !request.keepAlive { connection.cancel() }
                        })
                        if request.keepAlive { self.read(connection, rest) }
                    }
                } else if isComplete || error != nil || buffer.count > 16 << 20 {
                    connection.cancel()
                } else {
                    self.read(connection, buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.path.split(separator: "?").first == "/mcp" else { return HTTPResponse(status: 404) }
        if let origin = request.headers["origin"],
           !(origin.hasPrefix("http://127.0.0.1") || origin.hasPrefix("http://localhost")) {
            return HTTPResponse(status: 403)
        }
        guard request.headers["authorization"] == "Bearer \(Self.token)" else {
            return HTTPResponse(status: 401, json: ["error": "Pubbles needs its token; copy the setup again from Pubbles' menubar"])
        }
        guard request.method == "POST" else { return HTTPResponse(status: 405, headers: ["Allow": "POST"]) }
        guard let body = try? JSONSerialization.jsonObject(with: request.body) else {
            return HTTPResponse(status: 400, json: Self.error(nil, -32700, "Parse error"))
        }
        if let batch = body as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for message in batch {
                if let reply = await handle(message) { replies.append(reply) }
            }
            return replies.isEmpty ? HTTPResponse(status: 202) : HTTPResponse(status: 200, json: replies)
        }
        guard let message = body as? [String: Any] else {
            return HTTPResponse(status: 400, json: Self.error(nil, -32600, "Invalid request"))
        }
        guard let reply = await handle(message) else { return HTTPResponse(status: 202) }
        return HTTPResponse(status: 200, json: reply)
    }

    // MARK: JSON-RPC

    /// The reply to one message, or nil for notifications (and responses from the client).
    private func handle(_ message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil } // notification, e.g. notifications/initialized

        switch method {
        case "initialize":
            if let name = (params["clientInfo"] as? [String: Any])?["name"] as? String { tools.clientName = name }
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            return Self.result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "pubbles", "version": appVersion],
                "instructions": tools.instructions,
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": tools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.error(id, -32602, "Missing tool name") }
            return Self.result(id, await tools.call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return Self.error(id, -32601, "Method not found: \(method)")
        }
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var keepAlive: Bool

    /// One complete request from the front of `data`, and whatever follows it.
    static func parse(_ data: Data) -> (HTTPRequest, Data)? {
        let data = Data(data)
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var lines = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let request = HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: data[bodyStart..<bodyStart + length],
            keepAlive: headers["connection"]?.lowercased() != "close"
        )
        return (request, Data(data[(bodyStart + length)...]))
    }
}

private struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }

    init(status: Int, json: Any) {
        self.status = status
        body = (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data()
        headers["Content-Type"] = "application/json"
    }

    private static let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                                  403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"]

    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "OK")\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }
}
