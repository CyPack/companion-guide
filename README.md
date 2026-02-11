# The Vibe Companion - Deployment Guide with Tailscale

> **Claude Code & Codex CLI Web Interface** -- Deploy, secure, and manage Companion behind Tailscale on Fedora Linux.
>
> Written: 2026-02-10 | Updated: 2026-02-11 | OS: Fedora 43 | Companion: v0.15.0 (via bunx) | Tailscale: 1.92.5

---

## TL;DR Quick Deploy

For experienced users who just want to get it running:

```bash
# 1. Install Bun (download first, review, then execute)
curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh
bash /tmp/bun-install.sh
source ~/.zshrc  # or ~/.bashrc depending on your shell

# 2. Test locally
~/.bun/bin/bunx the-vibe-companion
# Visit http://localhost:3456

# 3. Configure Tailscale serve (use 8443 if port 443 is occupied by Traefik/nginx)
tailscale serve --bg --https=8443 3456

# 4. Create systemd user service
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/vibe-companion.service << 'EOF'
[Unit]
Description=The Vibe Companion - Claude Code Web Interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/home/YOUR_USER
Environment=PATH=/home/YOUR_USER/.npm-global/bin:/home/YOUR_USER/.bun/bin:/home/YOUR_USER/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=BUN_INSTALL=/home/YOUR_USER/.bun
WorkingDirectory=/home/YOUR_USER
ExecStart=/home/YOUR_USER/.bun/bin/bunx the-vibe-companion
Restart=on-failure
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=60
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native

[Install]
WantedBy=default.target
EOF

# 5. Enable and start
systemctl --user daemon-reload
systemctl --user enable --now vibe-companion.service
loginctl enable-linger $(whoami)

# 6. Access
# https://<your-hostname>.<your-tailnet>.ts.net:8443
```

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Architecture](#3-architecture)
4. [Step-by-Step Installation](#4-step-by-step-installation)
5. [Tailscale Integration](#5-tailscale-integration)
6. [Systemd Service](#6-systemd-service)
7. [Firewall Configuration](#7-firewall-configuration)
8. [Security Assessment](#8-security-assessment)
9. [Troubleshooting](#9-troubleshooting)
10. [Quick Reference](#10-quick-reference)
11. [Lessons Learned](#11-lessons-learned)

---

## 1. Overview

### What is Companion?

[The Vibe Companion](https://github.com/The-Vibe-Company/companion) is an open-source web interface for Claude Code. It is built on a reverse-engineered WebSocket protocol (the undocumented `--sdk-url` flag in the Claude CLI) that allows you to interact with Claude Code sessions from a web browser instead of a terminal.

### What Problem Does It Solve?

- **Remote access**: Use Claude Code from any device with a browser -- no SSH or terminal needed.
- **Multi-session management**: Run and switch between multiple independent Claude Code sessions simultaneously.
- **Better UX**: Syntax-highlighted tool calls, real-time streaming with elapsed time, permission controls with input editing, cost tracking, and subagent visualization.
- **Collaboration**: Multiple browser tabs/devices can connect to the same session.

### Architecture Diagram

```
                          Tailscale Network (WireGuard)
                         ================================

  [Browser]                                              [Server: <your-hostname>]
  Any device on tailnet                                  <your-tailscale-ip>
       |                                                       |
       | HTTPS :8443                                           |
       |  (auto TLS cert                                       |
       |   via Tailscale)                                      |
       +-----> [Tailscale Serve :8443] ----proxy----> [Companion :3456]
                                                           |
                                                   [WebSocket Bridge]
                                                      /    |    \
                                              [Claude CLI] [CLI] [CLI]
                                               Session 1   S2    S3
                                                  |
                                           [MCP Servers]
                                           Playwright, Scrapling,
                                           Chrome DevTools, etc.
```

### Technology Stack

| Component | Technology |
|-----------|-----------|
| Runtime | Bun 1.3.9 |
| Server | Hono + native Bun WebSocket |
| Frontend | React 19 + TypeScript |
| State | Zustand |
| Styling | Tailwind CSS v4 |
| Build | Vite |
| Protocol | NDJSON (newline-delimited JSON) over WebSocket |

---

## 2. Prerequisites

### Required Software

| Software | Version | Purpose | Check Command |
|----------|---------|---------|---------------|
| Claude Code CLI | 2.1.x+ | The actual AI backend | `claude --version` |
| Bun | 1.3.x+ | JavaScript runtime (runs Companion) | `~/.bun/bin/bun --version` |
| Tailscale | 1.92.x+ | Secure networking and HTTPS | `tailscale version` |
| Node.js | 24.x+ | Required by some MCP servers | `node --version` |

### Required Accounts / Auth

- **Anthropic account**: Claude Code must be authenticated (`claude auth login` or existing session).
- **Tailscale account**: Node must be joined to a tailnet with HTTPS certificates enabled.

### System Requirements

- **OS**: Linux (tested on Fedora 43, kernel 6.18.7)
- **RAM**: 512MB minimum for Companion itself; each Claude Code session spawns additional processes (MCP servers, etc.) -- budget ~500MB per active session.
- **Ports**: 3456 (Companion), 8443 or 443 (Tailscale HTTPS serve)

### Pre-flight Checks

```bash
# Verify Claude Code is authenticated
claude --version
# Expected: 2.1.38 (Claude Code)

# Verify Tailscale is connected
tailscale status
# Expected: your node should appear as online

# Verify HTTPS certificates are enabled on your tailnet
# Go to: https://login.tailscale.com/admin/dns
# "HTTPS Certificates" must be enabled
```

---

## 3. Architecture

### How Companion Works

The Claude Code CLI has an undocumented `--sdk-url` flag that tells it to connect to an external WebSocket server instead of running interactively in a terminal. Companion implements this WebSocket server.

#### Session Lifecycle

```
1. User opens browser -> loads Companion web UI
2. User types a prompt and hits Enter
3. Companion server spawns a new Claude CLI process:
   claude --sdk-url ws://localhost:3456/ws/cli/<session-uuid> \
          --print --output-format stream-json --input-format stream-json \
          --verbose --model claude-opus-4-6 --permission-mode bypassPermissions -p
4. CLI connects back to the server via WebSocket
5. Server forwards the user's prompt to the CLI
6. CLI processes and streams responses back via NDJSON
7. Server relays responses to the browser in real-time
8. Tool calls trigger permission requests (if not bypassed)
```

#### NDJSON Protocol (Reverse-Engineered)

The protocol uses newline-delimited JSON messages with the following key types:

| Direction | Type | Purpose |
|-----------|------|---------|
| Server -> CLI | `user` | Send user prompts |
| CLI -> Server | `system/init` | Handshake: tools, model, session ID |
| CLI -> Server | `assistant` | Full LLM responses |
| CLI -> Server | `result` | Query completion: status, tokens, cost |
| CLI -> Server | `stream_event` | Token-by-token streaming |
| CLI -> Server | `tool_progress` | Heartbeats during long tool runs |
| Bidirectional | `control_request/response` | Permission flow for tool approval |
| CLI -> Server | `keep_alive` | Connection health (every ~10s) |

#### Tool Permission Flow

When the CLI needs to execute a tool:

1. CLI sends `control_request` with `subtype: "can_use_tool"` containing tool name and inputs
2. Server forwards to browser for user decision
3. User can: **Allow** (optionally editing inputs), or **Deny** (with reason)
4. Server sends `control_response` back to CLI
5. CLI executes (or skips) the tool accordingly

> **Note**: In the systemd service configuration, `--permission-mode bypassPermissions` is used, which auto-approves all tool calls. This is a security trade-off for unattended operation. See [Section 8](#8-security-assessment) for implications.

---

## 4. Step-by-Step Installation

### 4.1 Install Bun

Companion requires the [Bun](https://bun.sh/) JavaScript runtime. It does not run on Node.js.

```bash
curl -fsSL https://bun.sh/install | bash
```

**Post-install**: Bun installs to `~/.bun/bin/bun`. Add it to your PATH:

```bash
# Add to ~/.bashrc or ~/.zshrc
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Reload shell
source ~/.bashrc   # or source ~/.zshrc
```

**Verification**:

```bash
bun --version
# Expected: 1.3.9 (or newer)

which bun
# Expected: /home/YOUR_USER/.bun/bin/bun
```

### 4.2 Run Companion (Local Test)

```bash
bunx the-vibe-companion
```

`bunx` downloads and runs the latest version of `the-vibe-companion` from npm. On first run, it caches the package in `/tmp/bunx-<uid>-the-vibe-companion@latest/`.

**Expected output**:

```
[server] Companion started on http://localhost:3456
```

### 4.3 Verify Local Access

Open a browser and navigate to:

```
http://localhost:3456
```

You should see the Companion web interface. Create a new session, type a prompt, and verify that Claude responds.

**Verification checklist**:

- [ ] Web UI loads without errors
- [ ] New session can be created
- [ ] Claude responds to prompts
- [ ] Tool calls display in collapsible blocks
- [ ] Streaming works (token-by-token output visible)

Press `Ctrl+C` to stop the local test.

---

## 5. Tailscale Integration

### 5.1 Why Tailscale?

Companion listens on `localhost:3456` with **no authentication**. Exposing it directly to the internet would be dangerous. Tailscale provides:

- **Zero-config VPN**: Only devices on your tailnet can access the service
- **Automatic HTTPS**: Valid TLS certificates via Let's Encrypt, no configuration needed
- **Identity-based access**: Tailscale ACLs control who can reach your node
- **No port forwarding**: Works behind NAT, firewalls, carrier-grade NAT

### 5.2 Enable HTTPS Certificates

Before using `tailscale serve`, ensure HTTPS certificates are enabled on your tailnet:

1. Go to [Tailscale Admin Console](https://login.tailscale.com/admin/dns)
2. Under **HTTPS Certificates**, click **Enable**
3. Wait a moment for the setting to propagate

### 5.3 Configure Tailscale Serve

#### Check for Port 443 Conflicts

If you have Traefik, nginx, or another reverse proxy on the machine, port 443 may already be in use:

```bash
ss -tlnp | grep ':443'
```

If port 443 is occupied (as it was in our case with Traefik):

```
LISTEN  0  4096  0.0.0.0:443  0.0.0.0:*
LISTEN  0  4096     [::]:443     [::]:*
```

You must use an alternative port.

#### Configure Serve on Port 8443

```bash
tailscale serve --bg --https=8443 3456
```

**Flags explained**:

| Flag | Purpose |
|------|---------|
| `--bg` | Run in background (persistent across Tailscale restarts) |
| `--https 8443` | Listen on HTTPS port 8443 instead of default 443 |
| `http://127.0.0.1:3456` | Proxy to local Companion instance |

#### If Port 443 Is Free

If nothing else uses port 443, you can use the default:

```bash
sudo tailscale serve --bg --https 443 http://127.0.0.1:3456
```

### 5.4 Verify Tailscale Serve

```bash
tailscale serve status
```

**Expected output**:

```
https://<your-hostname>.<your-tailnet>.ts.net:8443 (tailnet only)
|-- / proxy http://127.0.0.1:3456
```

**Test access from the same machine**:

```bash
curl -sI https://<your-hostname>.<your-tailnet>.ts.net:8443
# Expected: HTTP/2 200
```

**Test access from another tailnet device**: Open a browser on any other device connected to the same tailnet and navigate to:

```
https://<your-hostname>.<your-tailnet>.ts.net:8443
```

> **CUSTOMIZE**: Replace `<your-hostname>.<your-tailnet>.ts.net` with your actual Tailscale DNS name. Find it with:
> ```bash
> tailscale status --json | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))"
> ```

### 5.5 Tailscale Serve Internals

Tailscale serve works by:

1. Binding to the Tailscale IP address (<your-tailscale-ip>) on port 8443
2. Terminating TLS using auto-provisioned Let's Encrypt certificates
3. Proxying decrypted HTTP traffic to `127.0.0.1:3456`
4. WebSocket connections (`Upgrade: websocket`) are transparently proxied

The binding is visible in `ss`:

```
LISTEN  0  4096  <your-tailscale-ip>:8443   0.0.0.0:*
LISTEN  0  4096  [<your-tailscale-ipv6>]:8443  [::]:*
```

Note: It only binds to the Tailscale interface IPs, not `0.0.0.0`. This means port 8443 is not reachable from the LAN or internet -- only from the tailnet.

---

## 6. Systemd Service

### 6.1 Why a Systemd User Service?

- **Auto-start**: Companion starts automatically on boot (with lingering enabled)
- **Auto-restart**: Recovers from crashes automatically
- **Resource tracking**: systemd tracks all child processes (Claude CLI instances, MCP servers)
- **Security hardening**: Sandboxing directives limit what the process can do
- **User-level**: No root required; runs under your user account

### 6.2 Create the Service File

```bash
mkdir -p ~/.config/systemd/user
```

Write the service file:

```bash
cat > ~/.config/systemd/user/vibe-companion.service << 'SERVICEEOF'
[Unit]
Description=The Vibe Companion - Claude Code Web Interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/home/YOUR_USER
Environment=PATH=/home/YOUR_USER/.npm-global/bin:/home/YOUR_USER/.bun/bin:/home/YOUR_USER/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=BUN_INSTALL=/home/YOUR_USER/.bun
WorkingDirectory=/home/YOUR_USER
ExecStart=/home/YOUR_USER/.bun/bin/bunx the-vibe-companion
Restart=on-failure
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=60

# Security hardening
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native

[Install]
WantedBy=default.target
SERVICEEOF
```

> **CUSTOMIZE**: Replace `/home/YOUR_USER` with your actual home directory if different.

### 6.3 Security Hardening Directives Explained

| Directive | What It Does |
|-----------|-------------|
| `NoNewPrivileges=true` | Prevents the process (and children) from gaining new privileges via setuid/setgid |
| `ProtectKernelTunables=true` | Makes `/proc/sys/`, `/sys/` read-only |
| `ProtectKernelModules=true` | Blocks kernel module loading |
| `ProtectControlGroups=true` | Makes cgroup filesystem read-only |
| `RestrictRealtime=true` | Prevents real-time scheduling (anti-DoS) |
| `RestrictSUIDSGID=true` | Blocks creating setuid/setgid files |
| `SystemCallArchitectures=native` | Blocks syscalls from non-native architectures (e.g., 32-bit on 64-bit) |

### 6.4 Enable and Start

```bash
# Reload systemd to pick up the new service
systemctl --user daemon-reload

# Enable (start on boot) and start immediately
systemctl --user enable --now vibe-companion.service

# Enable lingering so user services run even when not logged in
loginctl enable-linger $(whoami)
```

### 6.5 Verify

```bash
systemctl --user status vibe-companion.service
```

**Expected output** (abbreviated):

```
● vibe-companion.service - The Vibe Companion - Claude Code Web Interface
     Loaded: loaded (/home/YOUR_USER/.config/systemd/user/vibe-companion.service; enabled; ...)
     Active: active (running) since ...
   Main PID: 1391350 (bunx)
      Tasks: 279 (limit: 18240)
     Memory: 576.2M
```

### 6.6 Management Commands

```bash
# Start the service
systemctl --user start vibe-companion.service

# Stop the service
systemctl --user stop vibe-companion.service

# Restart the service (kills all sessions!)
systemctl --user restart vibe-companion.service

# View real-time logs
journalctl --user -u vibe-companion.service -f

# View last 50 log lines
journalctl --user -u vibe-companion.service -n 50

# Disable auto-start
systemctl --user disable vibe-companion.service
```

> **Warning**: `systemctl --user restart` kills the main process and ALL child processes. This terminates all active Claude Code sessions. Users will need to create new sessions after a restart.

---

## 7. Firewall Configuration

### 7.1 The Docker + Tailscale + firewalld Challenge

If you run Docker on the same machine, firewall configuration becomes tricky. Docker manipulates iptables directly and creates its own chains, which can bypass firewalld rules.

### 7.2 Key Principle

Companion binds to `localhost:3456` (all interfaces via `0.0.0.0`). Tailscale serve binds only to the Tailscale IP. The goal is:

1. Port 3456 must NOT be reachable from the LAN or internet
2. Port 8443 must only be reachable via Tailscale
3. Docker networking must continue to work

### 7.3 Firewalld Zone Configuration

```bash
# Check active zones
sudo firewall-cmd --get-active-zones

# Ensure public zone blocks 3456 and 8443
# (They should not be open by default, but verify)
sudo firewall-cmd --zone=public --list-all

# If port 3456 is accidentally open, remove it
sudo firewall-cmd --zone=public --remove-port=3456/tcp --permanent

# Ensure Tailscale interface is in a trusted or separate zone
sudo firewall-cmd --zone=trusted --add-interface=tailscale0 --permanent

# Apply changes
sudo firewall-cmd --reload
```

### 7.4 Why Companion Is Already Protected

Even without explicit firewall rules:

1. **Tailscale serve** only binds port 8443 on the Tailscale IP (`<your-tailscale-ip>`), not on `0.0.0.0`. The LAN cannot reach it.
2. **Port 3456** (Companion itself) binds on `0.0.0.0:3456`, but firewalld's default `public` zone does not expose port 3456. Only services/ports explicitly opened in firewalld are reachable from external interfaces.
3. **Docker's bridge network** uses its own subnet and iptables chains. Docker containers can potentially reach `host:3456` via the Docker bridge gateway. See [Section 8](#8-security-assessment) for mitigation.

### 7.5 Rich Rules for Extra Protection

If you want defense-in-depth:

```bash
# Explicitly block port 3456 from non-localhost sources
sudo firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" port port="3456" protocol="tcp" reject' --permanent

# Block 8443 from non-Tailscale sources (if somehow exposed)
sudo firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" port port="8443" protocol="tcp" reject' --permanent

sudo firewall-cmd --reload
```

### 7.6 Verify Port Exposure

From another machine on the LAN (NOT on the tailnet):

```bash
# These should fail / timeout
nc -zv <LAN_IP_OF_SERVER> 3456    # Should: Connection refused
nc -zv <LAN_IP_OF_SERVER> 8443    # Should: Connection refused

# This should succeed (from a tailnet device)
nc -zv <your-hostname>.<your-tailnet>.ts.net 8443   # Should: Connection succeeded
```

---

## 8. Security Assessment

### 8.1 Threat Model

| Threat | Likelihood | Impact | Status |
|--------|-----------|--------|--------|
| Internet exposure of Companion | Low | Critical | **Mitigated** -- Tailscale-only access |
| LAN exposure of port 3456 | Low | High | **Mitigated** -- firewalld default deny |
| Unauthorized tailnet access | Low | High | **Mitigated** -- Tailscale identity + ACLs |
| Docker container reaching port 3456 | Medium | Medium | **Partially mitigated** -- see below |
| Session hijacking (no auth on Companion) | Medium | High | **Accepted risk** -- Tailscale is the auth layer |
| CLI runs with bypassPermissions | High (by design) | High | **Accepted risk** -- convenience trade-off |
| Supply chain (bunx fetches latest) | Low | Critical | **Known risk** -- pin version to mitigate |

### 8.2 What Is Protected

1. **Network isolation**: Companion is only reachable via the Tailscale overlay network. The WireGuard tunnel provides end-to-end encryption.
2. **HTTPS**: Tailscale serve provides valid TLS certificates. All browser traffic is encrypted.
3. **Identity-based access**: Only authenticated Tailscale nodes on your tailnet can reach the service. You can further restrict access with Tailscale ACLs.
4. **Process sandboxing**: The systemd service uses security hardening directives (NoNewPrivileges, ProtectKernel*, etc.).
5. **No root**: Companion runs as a regular user, not root.

### 8.3 Known Vulnerabilities and Risks

#### Risk 1: No Application-Level Authentication

Companion itself has **no login page, no authentication, no session tokens**. Anyone who can reach port 3456 (or 8443 via Tailscale) gets full access.

**Mitigation**: Tailscale serves as the authentication and authorization layer. Only devices on your tailnet can connect. Use Tailscale ACLs to restrict which nodes/users can access port 8443.

**Additional hardening** (optional):

```jsonc
// In your Tailscale ACL policy (https://login.tailscale.com/admin/acls)
{
  "acls": [
    {
      "action": "accept",
      "src": ["user:your-email@example.com"],
      "dst": ["<your-hostname>:8443"]
    }
  ]
}
```

#### Risk 2: bypassPermissions Mode

The CLI is launched with `--permission-mode bypassPermissions`, which means Claude can execute **any tool** (Bash commands, file writes, etc.) without user approval.

**Implication**: Claude can run arbitrary commands with the permissions of the user account. If a prompt injection or malicious instruction is processed, it could:

- Read/modify/delete files in the home directory
- Execute arbitrary shell commands
- Access credentials stored in the user's session
- Interact with any service the user can access

**Mitigation options**:

1. Remove `bypassPermissions` and use interactive approval (requires browser tab to be open)
2. Use `--permission-mode allowedTools` with a whitelist
3. Run Companion in a dedicated user account with limited permissions
4. Run inside a container with restricted filesystem access

#### Risk 3: `bunx` Fetches Latest Version

`bunx the-vibe-companion` always downloads and runs the latest published version from npm. If the package is compromised, you would run malicious code automatically on next restart.

**Mitigation**: Pin a specific version:

```bash
# Instead of:
ExecStart=/home/YOUR_USER/.bun/bin/bunx the-vibe-companion

# Pin a specific version:
ExecStart=/home/YOUR_USER/.bun/bin/bunx the-vibe-companion@1.2.3
```

Or install globally and run the binary directly:

```bash
~/.bun/bin/bun install -g the-vibe-companion@1.2.3
# Then use the installed binary in the service
ExecStart=/home/YOUR_USER/.bun/bin/the-vibe-companion
```

#### Risk 4: Docker Bridge Access

Docker containers on the same host can potentially reach `localhost:3456` via the Docker bridge gateway IP (usually `172.17.0.1`). This means a compromised container could access Companion without Tailscale authentication.

**Mitigation**: If this is a concern, bind Companion to `127.0.0.1` only (if configurable) or add an iptables rule:

```bash
sudo iptables -I DOCKER-USER -p tcp --dport 3456 -j DROP
```

### 8.4 Security Hardening Checklist

- [x] Companion only accessible via Tailscale (not LAN/internet)
- [x] HTTPS with valid certificates (Tailscale auto-TLS)
- [x] Systemd security directives applied
- [x] Service runs as unprivileged user
- [x] firewalld default-deny on public zone
- [x] User lingering enabled (service survives logout)
- [ ] Tailscale ACLs configured to restrict access (recommended)
- [ ] Version pinning for the-vibe-companion package (recommended)
- [ ] Dedicated service account instead of personal user (optional)
- [ ] Docker bridge access restricted (optional, if Docker is present)

---

## 9. Troubleshooting

> **Agent-Friendly Format**: Each issue follows `SYMPTOM → DIAGNOSE → FIX → VERIFY` pattern.
> Copy-paste the diagnostic commands directly. All commands are non-destructive.

### 9.1 Port 443 Conflict with Traefik/nginx

**Symptom**: `tailscale serve --bg --https 443 ...` fails or Traefik stops responding.

**Diagnose**:
```bash
# Check what's using port 443
ss -tlnp | grep ':443'
# Check Tailscale serve status
tailscale serve status
```

**Fix**:
```bash
# Use non-standard HTTPS port (avoids conflict)
tailscale serve --bg --https=8443 3456
```

**Verify**:
```bash
ss -tlnp | grep ':8443'
curl -k https://$(tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//')::8443 2>/dev/null | head -5
```

### 9.2 Tailscale Serve / HTTPS Certs Not Working

**Symptom**: `tailscale serve` returns an error about HTTPS certificates.

**Diagnose**:
```bash
tailscale serve status
tailscale status --self
```

**Fix**:
1. Go to [Tailscale Admin > DNS](https://login.tailscale.com/admin/dns) → enable "HTTPS Certificates" + MagicDNS
2. Then:
```bash
sudo systemctl restart tailscaled
tailscale serve --bg --https=8443 3456
```

**Verify**:
```bash
tailscale cert $(tailscale status --self --json | jq -r '.Self.DNSName' | sed 's/\.$//')
```

### 9.3 WebSocket Connection Failures

**Symptom**: Browser loads the UI but sessions do not start or disconnect immediately.

**Diagnose**:
```bash
# 1. Is the service running?
systemctl --user status vibe-companion.service --no-pager | head -10

# 2. Is port 3456 listening?
ss -tlnp | grep 3456

# 3. Recent errors in logs?
journalctl --user -u vibe-companion.service -n 30 --no-pager | grep -iE "error|fail|crash|panic"

# 4. Test HTTP endpoint
curl -s http://localhost:3456/api/backends
```

**Fix** (depends on diagnosis):
```bash
# Service not running → restart it
systemctl --user restart vibe-companion.service

# Claude CLI not found → check PATH in service
grep "PATH=" ~/.config/systemd/user/vibe-companion.service

# Claude CLI not authenticated → login
claude auth login
```

**Verify**:
```bash
curl -s http://localhost:3456/api/backends | python3 -m json.tool
# Expected: both claude and codex backends listed
```

### 9.4 "bun: command not found" in systemd

**Symptom**: Service fails to start with "bun not found" or "bunx not found".

**Diagnose**:
```bash
# Check service logs
journalctl --user -u vibe-companion.service -n 10 --no-pager

# Check if bun exists
ls -la ~/.bun/bin/bun ~/.bun/bin/bunx 2>&1

# Compare shell PATH vs service PATH
echo "Shell: $(which bun 2>/dev/null || echo 'not found')"
grep "PATH=" ~/.config/systemd/user/vibe-companion.service
```

**Fix**:
```bash
# Ensure service PATH includes all needed directories
# Edit ~/.config/systemd/user/vibe-companion.service:
# Environment=PATH=/home/YOUR_USER/.npm-global/bin:/home/YOUR_USER/.bun/bin:/home/YOUR_USER/.local/bin:/usr/local/bin:/usr/bin:/bin

systemctl --user daemon-reload
systemctl --user restart vibe-companion.service
```

**Verify**:
```bash
systemctl --user status vibe-companion.service --no-pager | head -5
# Expected: Active: active (running)
```

### 9.5 Service Starts But No Sessions Can Be Created

**Symptom**: Companion web UI loads, but clicking "New Session" fails.

**Diagnose**:
```bash
# 1. Check backends availability
curl -s http://localhost:3456/api/backends

# 2. Check CLI binaries
which claude && claude --version
which codex && codex --version

# 3. Check spawn errors
journalctl --user -u vibe-companion.service --no-pager | grep -iE "spawn|ENOENT|not found" | tail -10
```

**Fix** (depends on diagnosis):
```bash
# Backend shows available:false → CLI not in service PATH
# Add missing path to service file, then:
systemctl --user daemon-reload && systemctl --user restart vibe-companion.service

# CLI not authenticated
claude auth login   # for Claude Code
codex login         # for Codex CLI
```

**Verify**:
```bash
curl -s http://localhost:3456/api/backends
# Expected: {"id":"claude","available":true}, {"id":"codex","available":true}
```

### 9.6 Codex Backend Shows "available: false"

**Symptom**: Companion only shows Claude Code, Codex option is greyed out or missing.

**Diagnose**:
```bash
# 1. Is codex installed?
which codex && codex --version

# 2. Is codex in service PATH?
grep "PATH=" ~/.config/systemd/user/vibe-companion.service

# 3. Backend API check
curl -s http://localhost:3456/api/backends | python3 -m json.tool
```

**Fix**:
```bash
# Install codex if missing
npm install -g @openai/codex

# Add npm-global to service PATH if missing
# ~/.config/systemd/user/vibe-companion.service should have:
# Environment=PATH=/home/YOUR_USER/.npm-global/bin:/home/YOUR_USER/.bun/bin:...

systemctl --user daemon-reload
systemctl --user restart vibe-companion.service
```

**Verify**:
```bash
curl -s http://localhost:3456/api/backends | grep codex
# Expected: "available":true
```

### 9.7 High Memory Usage

**Symptom**: The service consumes several GB of memory.

**Diagnose**:
```bash
# Check memory usage
systemctl --user status vibe-companion.service --no-pager | grep Memory

# Count child processes per session
systemctl --user status vibe-companion.service --no-pager | grep -c "claude\|codex\|node\|python"

# System-wide memory
free -h
```

**Fix**:
```bash
# Option 1: Close unused sessions from browser UI

# Option 2: Add memory limits to service file
# Add under [Service]:
#   MemoryMax=4G
#   MemorySwapMax=2G
systemctl --user daemon-reload
systemctl --user restart vibe-companion.service

# Option 3: Nuclear - restart service (kills all sessions)
systemctl --user restart vibe-companion.service
```

**Verify**:
```bash
systemctl --user status vibe-companion.service --no-pager | grep Memory
```

### 9.8 Service Does Not Start on Boot

**Symptom**: After reboot, Companion is not running.

**Diagnose**:
```bash
# Check service enabled
systemctl --user is-enabled vibe-companion.service

# Check lingering
loginctl show-user $(whoami) | grep Linger
```

**Fix**:
```bash
# Enable service (if not)
systemctl --user enable vibe-companion.service

# Enable lingering (required for boot-start without login)
loginctl enable-linger $(whoami)
```

**Verify**:
```bash
systemctl --user is-enabled vibe-companion.service
# Expected: enabled
loginctl show-user $(whoami) | grep Linger
# Expected: Linger=yes
```

### 9.9 Updating Companion to Latest Version

**Symptom**: Running an old version, want to update.

**Diagnose**:
```bash
# Check current version
cat /tmp/bunx-$(id -u)-the-vibe-companion@latest/node_modules/the-vibe-companion/package.json 2>/dev/null | grep '"version"'

# Check latest available
npm view the-vibe-companion version
```

**Fix**:
```bash
# 1. Stop service
systemctl --user stop vibe-companion.service

# 2. Clear bun cache
find /tmp/bunx-$(id -u)-the-vibe-companion@latest -delete 2>/dev/null

# 3. Start service (auto-downloads latest)
systemctl --user start vibe-companion.service
```

**Verify**:
```bash
sleep 5
cat /tmp/bunx-$(id -u)-the-vibe-companion@latest/node_modules/the-vibe-companion/package.json | grep '"version"'
curl -s http://localhost:3456/api/backends | python3 -m json.tool
systemctl --user status vibe-companion.service --no-pager | head -5
```

---

## 10. Quick Reference

### Access URLs

| What | URL |
|------|-----|
| Local access (same machine) | `http://localhost:3456` |
| Tailscale access (any tailnet device) | `https://<your-hostname>.<your-tailnet>.ts.net:8443` |
| Tailscale access (by IP) | `https://<your-tailscale-ip>:8443` |

> **CUSTOMIZE**: Replace `<your-hostname>.<your-tailnet>.ts.net` with your Tailscale DNS name.

### Management Commands

```bash
# --- Service Management ---
systemctl --user start vibe-companion.service
systemctl --user stop vibe-companion.service
systemctl --user restart vibe-companion.service
systemctl --user status vibe-companion.service

# --- Logs ---
journalctl --user -u vibe-companion.service -f          # live tail
journalctl --user -u vibe-companion.service -n 100      # last 100 lines
journalctl --user -u vibe-companion.service --since today

# --- Tailscale ---
tailscale serve status                                    # show serve config
tailscale serve --bg --https=8443 3456   # reconfigure
sudo tailscale serve --bg --https 8443 off                # remove serve rule

# --- Bun ---
~/.bun/bin/bun --version                                  # check version
~/.bun/bin/bun upgrade                                    # upgrade bun

# --- Port Checks ---
ss -tlnp | grep 3456                                      # Companion port
ss -tlnp | grep 8443                                      # Tailscale serve port

# --- Process Tree ---
systemctl --user status vibe-companion.service            # shows all child processes
```

### Rollback Procedures

#### Remove Tailscale Serve

```bash
sudo tailscale serve --bg --https 8443 off
```

#### Stop and Disable the Service

```bash
systemctl --user stop vibe-companion.service
systemctl --user disable vibe-companion.service
```

#### Remove the Service File

```bash
rm ~/.config/systemd/user/vibe-companion.service
systemctl --user daemon-reload
```

#### Uninstall Bun (if desired)

```bash
rm -rf ~/.bun
# Remove PATH entries from ~/.bashrc or ~/.zshrc
```

#### Complete Cleanup (all-in-one)

```bash
# Stop service
systemctl --user stop vibe-companion.service
systemctl --user disable vibe-companion.service
rm ~/.config/systemd/user/vibe-companion.service
systemctl --user daemon-reload

# Remove Tailscale serve
sudo tailscale serve --bg --https 8443 off

# Remove bun cache
rm -rf /tmp/bunx-$(id -u)-the-vibe-companion@latest/
```

---

## 11. Lessons Learned

### Port Conflicts Are Common on Multi-Service Hosts

When deploying Tailscale serve on a machine that already runs Traefik, nginx, or any other reverse proxy, port 443 will be contested. The solution is straightforward: use a non-standard port (8443). Tailscale serve supports arbitrary HTTPS ports via `--https <port>`.

Tailscale binds only to its own interface IPs, so even if both services try port 443, they might not technically conflict if the existing service uses `0.0.0.0` and Tailscale uses `100.x.x.x`. However, using separate ports is cleaner and avoids subtle issues.

### systemd User Services Need Explicit PATH

Unlike system services, user services do not run through a login shell. Environment variables like PATH, HOME, and BUN_INSTALL must be explicitly set in the `[Service]` section. The most common failure mode is "command not found" because `~/.bun/bin` is not in PATH.

### lingering Is Required for Boot-Start

`loginctl enable-linger` is essential. Without it, user services only start when the user logs in and stop when they log out. With lingering, the user manager starts at boot and stays running.

### Memory Management for Multi-Session Workloads

Each Companion session spawns a full Claude Code CLI process plus all MCP servers configured in the user's `.claude.json`. With many MCP servers (Playwright, Chrome DevTools, Scrapling, CCGLM, etc.), each session can consume 200-500MB. Budget accordingly and consider limiting concurrent sessions on memory-constrained systems.

### `bunx` Always Fetches Latest: Pin for Production

For a production deployment, pinning the version is strongly recommended. `bunx the-vibe-companion` always downloads the latest published version. This is convenient for development but risky for production -- a bad publish could break your service on the next restart.

### Companion Has No Auth: Tailscale IS the Auth

This was a deliberate design choice by the Companion project. They expect you to handle access control externally. Tailscale is the ideal solution because it provides identity, encryption, and access control in a single layer without any configuration on the Companion side.

### WebSocket Through Reverse Proxies

Tailscale serve handles WebSocket upgrades transparently. Not all reverse proxies do. If you ever need to put Companion behind nginx or Traefik instead of Tailscale serve, you will need explicit WebSocket proxy configuration (`proxy_http_version 1.1`, `Upgrade` headers, etc.).

---

## Appendix A: File Locations

| File | Path |
|------|------|
| Systemd service | `~/.config/systemd/user/vibe-companion.service` |
| Bun binary | `~/.bun/bin/bun` |
| Claude CLI | `~/.local/bin/claude` |
| Codex CLI | `~/.npm-global/bin/codex` |
| Companion cache | `/tmp/bunx-$(id -u)-the-vibe-companion@latest/` |
| Claude Code config | `~/.claude.json` |
| Claude Code project config | `.claude/` (per project) |
| Tailscale serve state | Managed by Tailscale daemon |
| Companion logs | `journalctl --user -u vibe-companion.service` |

## Appendix B: Actual Versions Used

| Component | Version |
|-----------|---------|
| OS | Fedora Linux 43 (Workstation Edition) |
| Kernel | 6.18.7-200.fc43.x86_64 |
| Bun | 1.3.9 |
| Node.js | v24.13.0 |
| Claude Code CLI | 2.1.38 |
| Codex CLI | 0.98.0 |
| Companion | 0.15.0 |
| Docker | 29.2.0 |
| Tailscale | 1.92.5 |
| Tailscale IP | <your-tailscale-ip> |
| Tailscale DNS | <your-hostname>.<your-tailnet>.ts.net |
| Companion port | 3456 |
| HTTPS serve port | 8443 |

## Appendix C: WebSocket Protocol Quick Reference

For developing against or debugging the Companion WebSocket protocol:

```
Browser  <--WS-->  Companion Server  <--WS (NDJSON)-->  Claude CLI
                                     <--stdio (JSON-RPC)-->  Codex CLI
  :3456/ws/browser/<session-id>      :3456/ws/cli/<session-id>
```

> **v0.15.0+**: Companion supports two backends: **Claude Code** (WebSocket/NDJSON) and **Codex CLI** (stdio/JSON-RPC via CodexAdapter).

**CLI spawn command** (generated by Companion):

```bash
claude \
  --sdk-url ws://localhost:3456/ws/cli/<session-uuid> \
  --print \
  --output-format stream-json \
  --input-format stream-json \
  --verbose \
  --model claude-opus-4-6 \
  --permission-mode bypassPermissions \
  -p
```

**Key NDJSON message types**:

```jsonc
// CLI -> Server: Session init
{"type": "system", "subtype": "init", "session_id": "...", "tools": [...], "model": "..."}

// Server -> CLI: User prompt
{"type": "user", "content": "Hello, Claude"}

// CLI -> Server: Streaming token
{"type": "stream_event", ...}

// CLI -> Server: Tool permission request
{"type": "control_request", "subtype": "can_use_tool", "tool_name": "Bash", "input": {...}}

// Server -> CLI: Tool permission response
{"type": "control_response", "behavior": "allow", "updatedInput": {...}}

// CLI -> Server: Final result
{"type": "result", "status": "success", "usage": {"input_tokens": N, "output_tokens": N}, "cost": 0.XX}
```

---

*Guide created: 2026-02-10 | Created with Claude Code*
