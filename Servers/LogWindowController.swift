import AppKit
import SwiftUI
import Combine

class LogWindowController {
    private static var windows: [String: NSWindow] = [:]
    private static var cancellables: [String: AnyCancellable] = [:]

    static func show(serverId: String, manager: ServerManager) {
        // If window already exists, bring it to front
        if let existingWindow = windows[serverId] {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let state = manager.serverStates[serverId] else { return }

        // Create the SwiftUI view
        let logView = LogView(serverState: state)

        // Create hosting controller
        let hostingController = NSHostingController(rootView: logView)

        // Create window - nice big size for log viewing
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        // Set minimum size so it doesn't get too small
        window.minSize = NSSize(width: 600, height: 400)

        window.title = "\(state.server.name) - Logs"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false

        // Handle window close
        let delegate = WindowDelegate(serverId: serverId)
        window.delegate = delegate
        objc_setAssociatedObject(window, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        windows[serverId] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close(serverId: String) {
        windows[serverId]?.close()
        windows.removeValue(forKey: serverId)
        cancellables.removeValue(forKey: serverId)
    }

    private class WindowDelegate: NSObject, NSWindowDelegate {
        let serverId: String

        init(serverId: String) {
            self.serverId = serverId
        }

        func windowWillClose(_ notification: Notification) {
            LogWindowController.windows.removeValue(forKey: serverId)
            LogWindowController.cancellables.removeValue(forKey: serverId)
        }
    }
}

// MARK: - Log View

struct LogView: View {
    @ObservedObject var serverState: ServerState
    @State private var autoScroll = true
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(serverState.status.rawValue.capitalized)
                        .font(.system(size: 12, weight: .medium))
                }

                Spacer()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search logs...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                // Auto-scroll toggle
                Toggle(isOn: $autoScroll) {
                    Text("Auto-scroll")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                // Clear button
                Button(action: { serverState.clearLogs() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Log content - native NSTextView for proper selection
            LogTextView(
                logs: serverState.logBuffer,
                searchText: searchText,
                autoScroll: autoScroll
            )

            Divider()

            // Footer with stats
            HStack {
                Text("\(serverState.logBuffer.count) lines")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                if !searchText.isEmpty {
                    let matchCount = serverState.logBuffer.filter { $0.localizedCaseInsensitiveContains(searchText) }.count
                    Text("(\(matchCount) matching)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let port = serverState.server.port {
                    Text("Port \(port)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    var statusColor: Color {
        switch serverState.status {
        case .running:
            return serverState.isHealthy ? .green : .orange
        case .starting:
            return .yellow
        case .stopped:
            return .gray
        case .crashed:
            return .red
        case .cooldown:
            return .orange
        }
    }
}

// MARK: - Native NSTextView for proper text selection

struct LogTextView: NSViewRepresentable {
    let logs: [String]
    let searchText: String
    let autoScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Build attributed string with colors
        let attributedString = NSMutableAttributedString()
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        for (index, line) in logs.enumerated() {
            // Line number
            let lineNum = String(format: "%4d  ", index + 1)
            let lineNumAttr = NSAttributedString(
                string: lineNum,
                attributes: [
                    .font: defaultFont,
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            attributedString.append(lineNumAttr)

            // Line content with color
            let color = colorForLine(line)
            let lineAttr = NSAttributedString(
                string: line + "\n",
                attributes: [
                    .font: defaultFont,
                    .foregroundColor: color
                ]
            )
            attributedString.append(lineAttr)
        }

        // Only update if content changed
        if textView.attributedString() != attributedString {
            let wasAtBottom = isScrolledToBottom(scrollView)
            textView.textStorage?.setAttributedString(attributedString)

            // Auto-scroll to bottom if enabled and was at bottom
            if autoScroll && wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        let documentView = scrollView.documentView!
        let currentScroll = clipView.bounds.origin.y + clipView.bounds.height
        let documentHeight = documentView.frame.height
        return currentScroll >= documentHeight - 50
    }

    private func colorForLine(_ line: String) -> NSColor {
        if line.contains("[stderr]") || line.lowercased().contains("error") {
            return NSColor.systemRed
        } else if line.lowercased().contains("warn") {
            return NSColor.systemOrange
        } else if line.hasPrefix("[system]") {
            return NSColor.systemBlue
        }
        return NSColor.labelColor
    }
}
