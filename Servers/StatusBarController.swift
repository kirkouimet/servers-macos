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
    private var serverMenuItems: [String: NSMenuItem] = [:]
    private var launchAtLoginItem: NSMenuItem?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        setupStatusBarButton()
        setupMenu()

        // Start the API server
        serverApi = ServerApi(manager: serverManager, port: UInt16(serverManager.settings.resolvedApiPort))
        serverApi?.start()

        // Auto-start servers with autoStart: true
        for server in serverManager.settings.servers where server.shouldAutoStart {
            serverManager.start(serverId: server.id)
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
        let headerItem = NSMenuItem()
        let headerView = NSHostingView(rootView: MenuHeaderView())
        headerView.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        headerItem.view = headerView
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        // Server items - will be populated dynamically
        for server in serverManager.settings.servers {
            let item = createServerMenuItem(for: server)
            serverMenuItems[server.id] = item
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Global actions
        let startAllItem = NSMenuItem(title: "Start All Servers", action: #selector(startAllServers), keyEquivalent: "")
        startAllItem.target = self
        menu.addItem(startAllItem)

        let stopAllItem = NSMenuItem(title: "Stop All Servers", action: #selector(stopAllServers), keyEquivalent: "")
        stopAllItem.target = self
        menu.addItem(stopAllItem)

        menu.addItem(NSMenuItem.separator())

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

    private func createServerMenuItem(for server: Server) -> NSMenuItem {
        let item = NSMenuItem(title: server.name, action: nil, keyEquivalent: "")

        let submenu = NSMenu()

        // Status row (will be updated dynamically)
        let statusItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = 1  // Tag for finding later
        submenu.addItem(statusItem)

        submenu.addItem(NSMenuItem.separator())

        // Actions
        let startItem = NSMenuItem(title: "Start", action: #selector(startServer(_:)), keyEquivalent: "")
        startItem.target = self
        startItem.representedObject = server.id
        startItem.tag = 2
        submenu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop", action: #selector(stopServer(_:)), keyEquivalent: "")
        stopItem.target = self
        stopItem.representedObject = server.id
        stopItem.tag = 3
        submenu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "Restart", action: #selector(restartServer(_:)), keyEquivalent: "")
        restartItem.target = self
        restartItem.representedObject = server.id
        submenu.addItem(restartItem)

        submenu.addItem(NSMenuItem.separator())

        let logsItem = NSMenuItem(title: "View Logs...", action: #selector(viewLogs(_:)), keyEquivalent: "")
        logsItem.target = self
        logsItem.representedObject = server.id
        submenu.addItem(logsItem)

        if let port = server.port {
            let openItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = port
            submenu.addItem(openItem)
        }

        item.submenu = submenu
        return item
    }

    private func startObservingServers() {
        // Observe each server state
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
        guard let menuItem = serverMenuItems[id],
              let submenu = menuItem.submenu else { return }

        // Update the main item title with status indicator
        let indicator: String
        switch status {
        case .running:
            indicator = isHealthy ? "●" : "◐"
        case .starting:
            indicator = "◑"
        case .stopped:
            indicator = "○"
        case .crashed:
            indicator = "✕"
        case .cooldown:
            indicator = "⏳"
        }

        let server = serverManager.settings.servers.first { $0.id == id }
        menuItem.title = "\(indicator) \(server?.name ?? id)"

        // Update status text in submenu
        if let statusItem = submenu.item(withTag: 1) {
            var statusText = "Status: \(status.rawValue.capitalized)"
            if status == .running && isHealthy {
                statusText += " (healthy)"
            } else if status == .running && !isHealthy {
                statusText += " (unhealthy)"
            }
            statusItem.title = statusText
        }

        // Enable/disable start/stop based on current state
        if let startItem = submenu.item(withTag: 2) {
            startItem.isEnabled = status == .stopped || status == .crashed
        }
        if let stopItem = submenu.item(withTag: 3) {
            stopItem.isEnabled = status == .running || status == .starting
        }
    }

    // MARK: - Actions

    @objc func startServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        serverManager.start(serverId: id)
    }

    @objc func stopServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        serverManager.stop(serverId: id)
    }

    @objc func restartServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        serverManager.restart(serverId: id)
    }

    @objc func viewLogs(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        LogWindowController.show(serverId: id, manager: serverManager)
    }

    @objc func openInBrowser(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else { return }
        if let url = URL(string: "http://localhost:\(port)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func startAllServers() {
        serverManager.startAll()
    }

    @objc func stopAllServers() {
        serverManager.stopAll()
    }

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
