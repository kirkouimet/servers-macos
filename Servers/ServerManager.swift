import Foundation
import Combine

class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var serverStates: [String: ServerState] = [:]
    @Published var settings: ServerSettings?
    @Published var configError: String?

    private var healthCheckTimers: [String: Timer] = [:]
    private let nodeEnvPath = "/Users/kirkouimet/.nvm/versions/node/v24.11.1/bin"

    init() {
        if let loaded = ServerSettings.load() {
            self.settings = loaded
            setupServers()
        } else {
            self.configError = "Failed to load ~/.servers/settings.json"
        }
    }

    private func setupServers() {
        guard let settings = settings else { return }
        for server in settings.servers {
            serverStates[server.id] = ServerState(server: server)
        }
    }

    func reloadSettings() {
        // Stop all servers first
        for id in serverStates.keys {
            stop(serverId: id)
        }

        // Reload and setup
        if let loaded = ServerSettings.load() {
            settings = loaded
            configError = nil
            serverStates.removeAll()
            setupServers()
        } else {
            configError = "Failed to load ~/.servers/settings.json"
        }
    }

    // MARK: - Server Control

    func start(serverId: String) {
        guard let state = serverStates[serverId] else { return }
        guard state.process == nil || state.process?.isRunning == false else {
            state.status = .running
            return
        }

        state.status = .starting
        state.lastError = nil

        // Kill any orphaned processes
        killExistingProcesses(for: state.server)

        // Remove stale lock files for Next.js
        let lockPath = state.server.expandedPath + "/.next/dev/lock"
        try? FileManager.default.removeItem(atPath: lockPath)

        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: state.server.expandedPath)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")

        // Build command with proper PATH
        let fullCommand = "export PATH=\(nodeEnvPath):$PATH && exec \(state.server.command)"
        process.arguments = ["-c", fullCommand]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(nodeEnvPath):" + (env["PATH"] ?? "")
        env["FORCE_COLOR"] = "1"  // Keep colors in output
        process.environment = env

        // Setup pipes for stdout/stderr capture
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Read stdout in background
        readPipeAsync(pipe: stdoutPipe, state: state, prefix: "")

        // Read stderr in background
        readPipeAsync(pipe: stderrPipe, state: state, prefix: "[stderr] ")

        process.terminationHandler = { [weak self, weak state] proc in
            DispatchQueue.main.async {
                guard let self = self, let state = state else { return }

                let exitCode = proc.terminationStatus
                state.appendLog("[system] Process exited with code \(exitCode)")

                if exitCode != 0 {
                    state.status = .crashed
                    state.lastError = "Exit code: \(exitCode)"
                    self.handleCrash(state: state)
                } else {
                    state.status = .stopped
                }

                state.isHealthy = false
            }
        }

        do {
            try process.run()
            state.process = process
            state.pid = process.processIdentifier
            state.status = .running
            state.appendLog("[system] Started with PID \(process.processIdentifier)")

            // Start health checks if port is configured
            startHealthCheck(for: state)

        } catch {
            state.status = .crashed
            state.lastError = error.localizedDescription
            state.appendLog("[system] Failed to start: \(error.localizedDescription)")
        }
    }

    func stop(serverId: String) {
        guard let state = serverStates[serverId] else { return }

        stopHealthCheck(for: state)

        // Cancel cooldown
        state.inCooldown = false
        state.crashTimes.removeAll()

        if state.pid > 0 {
            // Kill the process group
            kill(-state.pid, SIGTERM)

            // Give it a moment to terminate gracefully
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if state.process?.isRunning == true {
                    kill(-state.pid, SIGKILL)
                }
            }
        }

        state.process?.terminate()
        state.process = nil
        state.pid = 0
        state.status = .stopped
        state.isHealthy = false
        state.appendLog("[system] Stopped")

        // Kill any orphaned processes
        killExistingProcesses(for: state.server)
    }

    func restart(serverId: String) {
        guard let state = serverStates[serverId] else { return }

        // Reset crash tracking on manual restart
        state.inCooldown = false
        state.crashTimes.removeAll()

        state.appendLog("[system] Restarting...")
        stop(serverId: serverId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start(serverId: serverId)
        }
    }

    func startAll() {
        for id in serverStates.keys {
            start(serverId: id)
        }
    }

    func stopAll() {
        for id in serverStates.keys {
            stop(serverId: id)
        }
    }

    /// Synchronously force-kill all server processes. Use when quitting app.
    func forceStopAll() {
        // Collect all ports first
        var portsToKill: [Int] = []

        for (_, state) in serverStates {
            // Kill process group immediately
            if state.pid > 0 {
                kill(-state.pid, SIGKILL)
            }
            state.process?.terminate()

            if let port = state.server.port {
                portsToKill.append(port)
            }

            state.process = nil
            state.pid = 0
            state.status = .stopped
        }

        // Delay for SIGKILL to propagate
        Thread.sleep(forTimeInterval: 0.5)

        // Kill any remaining processes on ports using direct PIDs
        for port in portsToKill {
            killProcessesOnPort(port)
        }

        // Delay to ensure ports are released
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func killProcessesOnPort(_ port: Int) {
        // Get PIDs using lsof synchronously
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", ":\(port)"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse PIDs and kill each one directly
                let pids = output.components(separatedBy: .newlines)
                    .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

                for pid in pids {
                    kill(pid, SIGKILL)
                }
            }
        } catch {
            // Ignore errors - no process on port is fine
        }
    }

    // MARK: - Log Access

    func getLogs(serverId: String, lines: Int = 100) -> [String] {
        return serverStates[serverId]?.getLogs(lines: lines) ?? []
    }

    func clearLogs(serverId: String) {
        serverStates[serverId]?.clearLogs()
    }

    func getServerInfo(serverId: String) -> ServerInfo? {
        guard let state = serverStates[serverId] else { return nil }
        return ServerInfo(
            id: state.server.id,
            name: state.server.name,
            status: state.status.rawValue,
            isHealthy: state.isHealthy,
            port: state.server.port,
            lastError: state.lastError
        )
    }

    func getAllServerInfo() -> [ServerInfo] {
        guard let settings = settings else { return [] }
        return settings.servers.compactMap { getServerInfo(serverId: $0.id) }
    }

    // MARK: - Private Helpers

    private func readPipeAsync(pipe: Pipe, state: ServerState, prefix: String) {
        let handle = pipe.fileHandleForReading

        DispatchQueue.global(qos: .background).async {
            var buffer = Data()

            while true {
                let data = handle.availableData
                if data.isEmpty { break }

                buffer.append(data)

                // Process complete lines
                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[..<newlineIndex]
                    buffer = buffer[(newlineIndex + 1)...]

                    if let line = String(data: lineData, encoding: .utf8) {
                        let cleanLine = self.stripAnsiCodes(line)
                        DispatchQueue.main.async {
                            state.appendLog(prefix + cleanLine)
                        }
                    }
                }
            }

            // Handle any remaining data without newline
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                let cleanLine = self.stripAnsiCodes(line)
                DispatchQueue.main.async {
                    state.appendLog(prefix + cleanLine)
                }
            }
        }
    }

    private func stripAnsiCodes(_ string: String) -> String {
        // Remove ANSI escape codes for cleaner logs
        let pattern = "\\x1B\\[[0-9;]*[a-zA-Z]"
        return string.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private func killExistingProcesses(for server: Server) {
        // Extract the main command (first word) for pkill
        let mainCommand = server.command.components(separatedBy: " ").first ?? server.command

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", "\(server.expandedPath).*\(mainCommand)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.3)
        } catch {
            // Ignore - no matching process is fine
        }
    }

    private func handleCrash(state: ServerState) {
        let now = Date()
        state.crashTimes.append(now)
        state.crashTimes = state.crashTimes.filter {
            now.timeIntervalSince($0) < state.crashWindowSeconds
        }

        if state.crashTimes.count >= state.maxCrashesBeforeCooldown {
            state.inCooldown = true
            state.status = .cooldown
            state.appendLog("[system] Too many crashes - cooldown for \(Int(state.cooldownSeconds/60)) minutes")

            DispatchQueue.main.asyncAfter(deadline: .now() + state.cooldownSeconds) { [weak self, weak state] in
                guard let self = self, let state = state else { return }
                state.inCooldown = false
                state.crashTimes.removeAll()
                state.appendLog("[system] Cooldown ended - restarting")
                self.start(serverId: state.server.id)
            }
            return
        }

        state.appendLog("[system] Crashed - restarting (\(state.crashTimes.count)/\(state.maxCrashesBeforeCooldown))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak state] in
            guard let self = self, let state = state, !state.inCooldown else { return }
            self.start(serverId: state.server.id)
        }
    }

    // MARK: - Health Checks

    private func startHealthCheck(for state: ServerState) {
        guard let port = state.server.port else { return }

        stopHealthCheck(for: state)

        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self, weak state] _ in
            guard let state = state else { return }
            self?.checkHealth(state: state, port: port)
        }

        healthCheckTimers[state.server.id] = timer

        // Initial check after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak state] in
            guard let state = state else { return }
            self?.checkHealth(state: state, port: port)
        }
    }

    private func stopHealthCheck(for state: ServerState) {
        healthCheckTimers[state.server.id]?.invalidate()
        healthCheckTimers.removeValue(forKey: state.server.id)
    }

    private func checkHealth(state: ServerState, port: Int) {
        // Use TCP socket check instead of HTTP to avoid polluting server logs
        // Resolves hostname to support both IPv4 and IPv6
        let hostname = state.server.hostname

        DispatchQueue.global(qos: .utility).async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC  // Allow both IPv4 and IPv6
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, String(port), &hints, &result)

            guard status == 0, let addrInfo = result else {
                DispatchQueue.main.async { state.isHealthy = false }
                return
            }
            defer { freeaddrinfo(result) }

            // Try each resolved address until one connects
            var info: UnsafeMutablePointer<addrinfo>? = addrInfo
            var connected = false

            while let ai = info {
                let sock = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
                if sock >= 0 {
                    // Set socket timeout
                    var timeout = timeval(tv_sec: 2, tv_usec: 0)
                    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                    if connect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                        connected = true
                        close(sock)
                        break
                    }
                    close(sock)
                }
                info = ai.pointee.ai_next
            }

            DispatchQueue.main.async {
                state.isHealthy = connected
            }
        }
    }
}

// MARK: - SSL Delegate for self-signed certs

class InsecureSSLDelegate: NSObject, URLSessionDelegate {
    static let shared = InsecureSSLDelegate()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
