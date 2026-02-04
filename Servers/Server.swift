import Foundation
import Combine

// MARK: - Server Model

struct Server: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let command: String
    let port: Int?
    let hostname: String
    let healthCheckPath: String?
    let https: Bool?
    let autoStart: Bool?

    var expandedPath: String {
        NSString(string: path).expandingTildeInPath
    }

    var useHttps: Bool {
        https ?? false
    }

    var shouldAutoStart: Bool {
        autoStart ?? false
    }

    init(id: String, name: String, path: String, command: String, port: Int? = nil, hostname: String, healthCheckPath: String? = nil, https: Bool? = nil, autoStart: Bool? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.command = command
        self.port = port
        self.hostname = hostname
        self.healthCheckPath = healthCheckPath ?? "/"
        self.https = https
        self.autoStart = autoStart
    }
}

// MARK: - Server Status

enum ServerStatus: String, Codable {
    case stopped = "stopped"
    case starting = "starting"
    case running = "running"
    case crashed = "crashed"
    case cooldown = "cooldown"
}

// MARK: - Server State (Runtime)

class ServerState: ObservableObject {
    let server: Server
    @Published var status: ServerStatus = .stopped
    @Published var isHealthy: Bool = false
    @Published var lastError: String?

    var process: Process?
    var pid: pid_t = 0
    @Published var logBuffer: [String] = []
    var crashTimes: [Date] = []

    let maxLogLines = 5000
    let maxCrashesBeforeCooldown = 3
    let crashWindowSeconds: TimeInterval = 60
    let cooldownSeconds: TimeInterval = 300
    var inCooldown = false

    init(server: Server) {
        self.server = server
    }

    func appendLog(_ line: String) {
        logBuffer.append(line)
        if logBuffer.count > maxLogLines {
            logBuffer.removeFirst(logBuffer.count - maxLogLines)
        }
    }

    func getLogs(lines: Int = 100) -> [String] {
        let count = min(lines, logBuffer.count)
        return Array(logBuffer.suffix(count))
    }

    func clearLogs() {
        logBuffer.removeAll()
    }
}

// MARK: - Config

struct ServerSettings: Codable {
    let servers: [Server]
    let apiPort: Int?

    var resolvedApiPort: Int {
        apiPort ?? 7378
    }

    static let defaultSettingsPath = "~/.servers/settings.json"

    static func load() -> ServerSettings? {
        let path = NSString(string: defaultSettingsPath).expandingTildeInPath

        guard let data = FileManager.default.contents(atPath: path) else {
            print("Error: No settings file found at \(path)")
            return nil
        }

        do {
            return try JSONDecoder().decode(ServerSettings.self, from: data)
        } catch {
            print("Error: Failed to parse settings file: \(error)")
            return nil
        }
    }

    func save() {
        let path = NSString(string: ServerSettings.defaultSettingsPath).expandingTildeInPath
        let dir = (path as NSString).deletingLastPathComponent

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - API Response Types

struct ServerListResponse: Codable {
    let servers: [ServerInfo]
}

struct ServerInfo: Codable {
    let id: String
    let name: String
    let status: String
    let isHealthy: Bool
    let port: Int?
    let lastError: String?
}

struct LogsResponse: Codable {
    let id: String
    let lines: [String]
    let totalLines: Int
}

struct ActionResponse: Codable {
    let success: Bool
    let message: String
}
