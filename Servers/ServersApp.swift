import SwiftUI
import Darwin

@main
struct ServersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()

        // Hide dock icon - we're a menubar app
        NSApp.setActivationPolicy(.accessory)

        // Set up signal handlers for graceful shutdown
        setupSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up when app is terminating normally
        gracefulShutdown()
    }

    private func setupSignalHandlers() {
        // Ignore default signal handling so we can handle it ourselves
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        // Handle SIGTERM (sent by pkill -TERM)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { [weak self] in
            print("[Servers] Received SIGTERM - shutting down gracefully...")
            self?.gracefulShutdown()
            exit(0)
        }
        sigtermSource?.resume()

        // Handle SIGINT (Ctrl+C)
        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource?.setEventHandler { [weak self] in
            print("[Servers] Received SIGINT - shutting down gracefully...")
            self?.gracefulShutdown()
            exit(0)
        }
        sigintSource?.resume()
    }

    private func gracefulShutdown() {
        print("[Servers] Stopping all servers...")

        // Stop the API server
        statusBarController?.serverAPI?.stop()

        // Stop all managed dev servers (this kills the process groups)
        ServerManager.shared.stopAll()

        // Give processes a moment to die
        Thread.sleep(forTimeInterval: 0.5)

        print("[Servers] Shutdown complete.")
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Servers Settings")
                .font(.headline)
            Text("Coming soon...")
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 300, height: 200)
    }
}
