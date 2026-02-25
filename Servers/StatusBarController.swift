import AppKit
import SwiftUI
import Combine
import ServiceManagement

class StatusBarController: ObservableObject {
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var cancellables = Set<AnyCancellable>()

    // Server management
    let serverManager = ServerManager.shared
    var serverApi: ServerApi?

    // Menu items we need to update dynamically
    private var serverLabelItems: [String: NSMenuItem] = [:]
    private var serverButtonItems: [String: NSMenuItem] = [:]
    private var launchAtLoginItem: NSMenuItem?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        setupStatusBarButton()
        setupMenu()

        // Start the API server
        if let settings = serverManager.settings {
            serverApi = ServerApi(manager: serverManager, port: UInt16(settings.resolvedApiPort))
            serverApi?.start()

            // Auto-start servers with autoStart: true
            for server in settings.servers where server.shouldAutoStart {
                serverManager.start(serverId: server.id)
            }
        }

        // Subscribe to server state changes
        startObservingServers()
    }

    deinit {
        serverApi?.stop()
        serverManager.forceStopAll()
    }

    private func setupStatusBarButton() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Servers")
            image?.isTemplate = true  // Adapts to light/dark mode
            button.image = image
        }
        statusItem.menu = menu
    }

    private func setupMenu() {
        // Header
        let headerMenuItem = NSMenuItem()
        let headerView = NSHostingView(rootView: MenuHeaderView())
        headerView.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        headerMenuItem.view = headerView
        menu.addItem(headerMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Server items — clickable label + button row per server
        if let settings = serverManager.settings {
            for server in settings.servers {
                let (labelItem, buttonItem) = createServerMenuItems(for: server)
                serverLabelItems[server.id] = labelItem
                serverButtonItems[server.id] = buttonItem
                menu.addItem(labelItem)
                menu.addItem(buttonItem)
                menu.addItem(NSMenuItem.separator())
            }
        } else if let error = serverManager.configError {
            let errorItem = NSMenuItem(title: "\(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Settings
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        self.launchAtLoginItem = launchItem
        menu.addItem(launchItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Servers", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func createServerMenuItems(for server: Server) -> (NSMenuItem, NSMenuItem) {
        let state = serverManager.serverStates[server.id]
        let status = state?.status ?? .stopped

        // Row 1: Clickable label — opens control window
        let labelItem = NSMenuItem()
        let portSuffix = server.port != nil ? ":" + String(server.port!) : ""
        let labelView = ServerLabelView(name: server.name, port: portSuffix, status: status)
        let labelHosting = NSHostingView(rootView: labelView)
        labelHosting.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        labelItem.view = labelHosting

        // Make the whole label clickable via a gesture inside the SwiftUI view
        // We'll use a tap gesture in ServerLabelView instead
        let labelViewWithAction = ServerLabelView(name: server.name, port: portSuffix, status: status, onTap: { [weak self] in
            self?.menu.cancelTracking()
            LogWindowController.show(serverId: server.id, manager: self?.serverManager ?? ServerManager.shared)
        })
        let labelHostingFinal = NSHostingView(rootView: labelViewWithAction)
        labelHostingFinal.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        labelItem.view = labelHostingFinal

        // Row 2: Buttons
        let buttonItem = NSMenuItem()
        let buttonsView = ServerControlButtons(
            status: status,
            onStart: { [weak self] in self?.serverManager.start(serverId: server.id) },
            onStop: { [weak self] in self?.serverManager.stop(serverId: server.id) },
            onRestart: { [weak self] in self?.serverManager.restart(serverId: server.id) },
            onOpenBrowser: server.port != nil ? { [weak self] in
                self?.menu.cancelTracking()
                let scheme = server.useHttps ? "https" : "http"
                let hostname = server.hostname
                if let url = URL(string: "\(scheme)://\(hostname):\(server.port!)") {
                    NSWorkspace.shared.open(url)
                }
            } : nil,
        )
        let wrappedButtons = buttonsView.padding(.horizontal, 14).padding(.vertical, 4).frame(width: 280, alignment: .leading)
        let buttonHosting = NSHostingView(rootView: wrappedButtons)
        buttonHosting.frame = NSRect(x: 0, y: 0, width: 280, height: 30)
        buttonItem.view = buttonHosting

        return (labelItem, buttonItem)
    }

    private func startObservingServers() {
        for (id, state) in serverManager.serverStates {
            state.$status
                .combineLatest(state.$isHealthy)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status, isHealthy in
                    self?.updateServerMenuItem(id: id, status: status, isHealthy: isHealthy)
                }
                .store(in: &cancellables)
        }
    }

    private func updateServerMenuItem(id: String, status: ServerStatus, isHealthy: Bool) {
        guard let server = serverManager.settings?.servers.first(where: { $0.id == id }) else { return }

        // Update label
        if let labelItem = serverLabelItems[id] {
            let portSuffix = server.port != nil ? ":" + String(server.port!) : ""
            let labelView = ServerLabelView(name: server.name, port: portSuffix, status: status, onTap: { [weak self] in
                self?.menu.cancelTracking()
                LogWindowController.show(serverId: server.id, manager: self?.serverManager ?? ServerManager.shared)
            })
            let hosting = NSHostingView(rootView: labelView)
            hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
            labelItem.view = hosting
        }

        // Update buttons
        if let buttonItem = serverButtonItems[id] {
            let buttonsView = ServerControlButtons(
                status: status,
                onStart: { [weak self] in self?.serverManager.start(serverId: server.id) },
                onStop: { [weak self] in self?.serverManager.stop(serverId: server.id) },
                onRestart: { [weak self] in self?.serverManager.restart(serverId: server.id) },
                onOpenBrowser: server.port != nil ? { [weak self] in
                    self?.menu.cancelTracking()
                    let scheme = server.useHttps ? "https" : "http"
                    let hostname = server.hostname
                    if let url = URL(string: "\(scheme)://\(hostname):\(server.port!)") {
                        NSWorkspace.shared.open(url)
                    }
                } : nil,
                )
            let wrappedButtons = buttonsView.padding(.horizontal, 14).padding(.vertical, 4).frame(width: 280, alignment: .leading)
            let hosting = NSHostingView(rootView: wrappedButtons)
            hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 30)
            buttonItem.view = hosting
        }
    }

    // MARK: - Actions

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                launchAtLoginItem?.state = .off
            } else {
                try SMAppService.mainApp.register()
                launchAtLoginItem?.state = .on
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    @objc func quitApp() {
        serverManager.forceStopAll()
        serverApi?.stop()
        // Give processes time to fully terminate and release ports
        Thread.sleep(forTimeInterval: 2.0)
        NSApp.terminate(nil)
    }
}

// MARK: - Menu Header View

struct MenuHeaderView: View {
    var body: some View {
        HStack {
            Text("Servers")
                .font(.system(size: 13, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(width: 280)
    }
}

// MARK: - Server Control Buttons (reused in menu and log window)

struct ServerControlButtons: View {
    let status: ServerStatus
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    var onOpenBrowser: (() -> Void)? = nil
    var size: ActionButton.Size = .small

    private var canStart: Bool {
        status == .stopped || status == .crashed
    }

    private var canStop: Bool {
        status == .running || status == .starting
    }

    var body: some View {
        HStack(spacing: 6) {
            if canStart {
                ActionButton(icon: "play.fill", color: .green, enabled: true, size: size, tooltip: "Start") {
                    onStart()
                }
            } else {
                ActionButton(icon: "stop.fill", color: .red, enabled: true, size: size, tooltip: "Stop") {
                    onStop()
                }
            }

            ActionButton(icon: "arrow.clockwise", color: .blue, enabled: canStop, size: size, tooltip: "Restart") {
                onRestart()
            }

            if let onOpenBrowser = onOpenBrowser {
                ActionButton(icon: "safari", color: .cyan, enabled: status == .running, size: size, tooltip: "Open in Browser") {
                    onOpenBrowser()
                }
            }
        }
    }
}

// MARK: - Server Label View (clickable row)

struct ServerLabelView: View {
    let name: String
    let port: String
    let status: ServerStatus
    var onTap: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer()

            if !port.isEmpty {
                Text(port)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(status == .running ? .green : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(width: 280, height: 26)
        .background(isHovered ? Color.primary.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .onTapGesture { onTap?() }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    enum Size {
        case small, medium

        var iconSize: CGFloat {
            switch self {
            case .small: return 11
            case .medium: return 13
            }
        }

        var frameWidth: CGFloat {
            switch self {
            case .small: return 28
            case .medium: return 32
            }
        }

        var frameHeight: CGFloat {
            switch self {
            case .small: return 22
            case .medium: return 26
            }
        }
    }

    let icon: String
    let color: Color
    let enabled: Bool
    var size: Size = .small
    var tooltip: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size.iconSize, weight: .medium))
            .foregroundStyle(enabled ? (isHovered ? .white : color) : .gray.opacity(0.4))
            .frame(width: size.frameWidth, height: size.frameHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                if enabled { isHovered = hovering }
            }
            .onTapGesture {
                guard enabled else { return }
                isPressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isPressed = false
                    action()
                }
            }
            .help(tooltip ?? "")
    }

    private var backgroundColor: Color {
        guard enabled else { return .clear }
        if isPressed {
            return color.opacity(0.7)
        } else if isHovered {
            return color.opacity(0.6)
        }
        return color.opacity(0.1)
    }

    private var borderColor: Color {
        guard enabled else { return .gray.opacity(0.15) }
        if isHovered {
            return color.opacity(0.8)
        }
        return color.opacity(0.25)
    }
}
