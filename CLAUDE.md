# Servers

macOS menubar app for managing local development servers. Runs as a UIElement (no dock icon).

## Architecture

```
Servers/
├── ServersApp.swift           # Entry point, AppDelegate, signal handlers
├── StatusBarController.swift  # Menubar UI, server status indicators
├── ServerManager.swift        # Process management, health checks
├── Server.swift               # Models (Server, ServerStatus, ServerState, ServerSettings)
├── ServerApi.swift            # REST API on port 7378
├── LogWindowController.swift  # Native log viewer window
```

## Settings

Location: `~/.servers/settings.json`

```json
{
    "servers": [
        {
            "id": "amp-server",
            "name": "Amp Server",
            "path": "~/Projects/amp/server",
            "command": "npx tsx server.ts",
            "port": 2878
        }
    ],
    "apiPort": 7378
}
```

## Status Indicators

- `●` Running & healthy
- `◐` Running but unhealthy
- `◑` Starting
- `○` Stopped
- `✕` Crashed
- `⏳` Cooldown (after 3 crashes in 60s)

## REST API (Port 7378)

**Endpoints:**

- `GET /servers` - List all servers
- `GET /servers/{id}` - Get single server
- `GET /servers/{id}/logs?lines=100` - Get logs
- `POST /servers/{id}/start` - Start server
- `POST /servers/{id}/stop` - Stop server
- `POST /servers/{id}/restart` - Restart server
- `POST /servers/{id}/clear-logs` - Clear logs
- `POST /servers/start-all` - Start all
- `POST /servers/stop-all` - Stop all
- `POST /servers/reload-settings` - Reload from disk

## Process Management

- SIGTERM first, SIGKILL after timeout
- Orphaned process cleanup via `pkill -9 -f`
- Health checks via TCP socket (5s interval, 2s timeout)
- Crash detection with cooldown (3 crashes/60s = 5min cooldown)
- Log buffering (5000 lines max per server)
- ANSI code stripping from stdout/stderr

## Signal Handling

AppDelegate catches SIGTERM and SIGINT for graceful shutdown. All child processes are terminated when the app exits.

## Log Window

- 1200x800 default, min 600x400
- Search functionality (case-insensitive)
- Auto-scroll toggle
- Color coding: errors (red), warnings (orange), system (blue)
- Monospace font with line numbers

## Menu Features

- Start/Stop/Restart individual servers
- Start All / Stop All
- View logs in native window
- Open in browser (for web servers)
- Launch at Login toggle (via SMAppService)

## Node.js Path

Resolved at runtime in `ServerManager.swift`. Priority: NVM (latest installed version) → Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`) → system fallback.

## Permissions

- No sandbox (required for process management)
- NSAllowsArbitraryLoads for local dev servers
- LSUIElement = true (menubar only, no dock)

## Building

```bash
# Open in Xcode
open Servers.xcodeproj
```
