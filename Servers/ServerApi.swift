import Foundation
import Network

class ServerApi {
    private var listener: NWListener?
    private let manager: ServerManager
    private let port: UInt16

    init(manager: ServerManager, port: UInt16 = 7378) {
        self.manager = manager
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[ServerApi] Listening on port \(self?.port ?? 0)")
                case .failed(let error):
                    print("[ServerApi] Failed: \(error)")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: .main)
        } catch {
            print("[ServerApi] Failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }

            guard let request = String(data: data, encoding: .utf8) else {
                self.sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
                return
            }

            self.routeRequest(request: request, connection: connection)
        }
    }

    private func routeRequest(request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
            return
        }

        let method = parts[0]
        let fullPath = parts[1]

        // Parse path and query string
        let pathComponents = fullPath.components(separatedBy: "?")
        let path = pathComponents[0]
        let queryString = pathComponents.count > 1 ? pathComponents[1] : ""
        let query = parseQueryString(queryString)

        // Route the request
        switch (method, path) {

        // GET /servers - List all servers
        case ("GET", "/servers"):
            let servers = manager.getAllServerInfo()
            sendResponse(connection: connection, status: 200, body: ["servers": servers])

        // GET /servers/:id - Get single server info
        case ("GET", _) where path.hasPrefix("/servers/") && !path.contains("/logs") && !path.contains("/start") && !path.contains("/stop") && !path.contains("/restart"):
            let id = String(path.dropFirst("/servers/".count))
            if let info = manager.getServerInfo(serverId: id) {
                sendResponse(connection: connection, status: 200, body: info)
            } else {
                sendResponse(connection: connection, status: 404, body: ["error": "Server not found"])
            }

        // GET /servers/:id/logs - Get server logs
        case ("GET", _) where path.hasSuffix("/logs"):
            let id = extractServerId(from: path, suffix: "/logs")
            let lines = Int(query["lines"] ?? "100") ?? 100
            let logs = manager.getLogs(serverId: id, lines: lines)
            let response = LogsResponse(
                id: id,
                lines: logs,
                totalLines: manager.serverStates[id]?.logBuffer.count ?? 0
            )
            sendResponse(connection: connection, status: 200, body: response)

        // POST /servers/:id/start - Start server
        case ("POST", _) where path.hasSuffix("/start"):
            let id = extractServerId(from: path, suffix: "/start")
            if manager.serverStates[id] != nil {
                manager.start(serverId: id)
                sendResponse(connection: connection, status: 200, body: ActionResponse(success: true, message: "Starting \(id)"))
            } else {
                sendResponse(connection: connection, status: 404, body: ActionResponse(success: false, message: "Server not found"))
            }

        // POST /servers/:id/stop - Stop server
        case ("POST", _) where path.hasSuffix("/stop"):
            let id = extractServerId(from: path, suffix: "/stop")
            if manager.serverStates[id] != nil {
                manager.stop(serverId: id)
                sendResponse(connection: connection, status: 200, body: ActionResponse(success: true, message: "Stopping \(id)"))
            } else {
                sendResponse(connection: connection, status: 404, body: ActionResponse(success: false, message: "Server not found"))
            }

        // POST /servers/:id/restart - Restart server
        case ("POST", _) where path.hasSuffix("/restart"):
            let id = extractServerId(from: path, suffix: "/restart")
            if manager.serverStates[id] != nil {
                manager.restart(serverId: id)
                sendResponse(connection: connection, status: 200, body: ActionResponse(success: true, message: "Restarting \(id)"))
            } else {
                sendResponse(connection: connection, status: 404, body: ActionResponse(success: false, message: "Server not found"))
            }

        // POST /servers/:id/clear-logs - Clear logs
        case ("POST", _) where path.hasSuffix("/clear-logs"):
            let id = extractServerId(from: path, suffix: "/clear-logs")
            if manager.serverStates[id] != nil {
                manager.clearLogs(serverId: id)
                sendResponse(connection: connection, status: 200, body: ActionResponse(success: true, message: "Logs cleared"))
            } else {
                sendResponse(connection: connection, status: 404, body: ActionResponse(success: false, message: "Server not found"))
            }

        // POST /servers/start-all
        case ("POST", "/servers/start-all"):
            manager.startAll()
            sendResponse(connection: connection, status: 200, body: ActionResponse(success: true, message: "Starting all servers"))

        // POST /servers/stop-all
        case ("POST", "/servers/stop-all"):
            manager.stopAll()
            sendResponse(connection: connection, status: 200, body: ActionResponse(success: true, message: "Stopping all servers"))

        // POST /servers/reload-settings
        case ("POST", "/servers/reload-settings"):
            manager.reloadSettings()
            sendResponse(connection: connection, status: 200, body: ActionResponse(success: true, message: "Settings reloaded"))

        default:
            sendResponse(connection: connection, status: 404, body: ["error": "Not found", "path": path])
        }
    }

    private func extractServerId(from path: String, suffix: String) -> String {
        var cleaned = path
        if cleaned.hasPrefix("/servers/") {
            cleaned = String(cleaned.dropFirst("/servers/".count))
        }
        if cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        return cleaned
    }

    private func parseQueryString(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return result
    }

    private func sendResponse<T: Encodable>(connection: NWConnection, status: Int, body: T) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var jsonData = Data()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            jsonData = try encoder.encode(body)
        } catch {
            jsonData = "{\"error\": \"JSON encoding failed\"}".data(using: .utf8)!
        }

        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(jsonData.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """

        var responseData = response.data(using: .utf8)!
        responseData.append(jsonData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
