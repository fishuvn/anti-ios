# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

- **iOS Client (`ios/`)**: Native SwiftUI (Swift 6, iOS 18.0+), XcodeGen `project.yml` + pure-Swift `AntiCore` Swift Package for models, Keychain-backed profile metadata, REST/WebSocket client, and Swift Testing unit tests. Compiled and run via Xcode on macOS.
- **Companion Remote Bridge (`bridge/`)**: Zero-dependency Node.js (v20+ ESM) HTTPS/HTTP + RFC 6455 WebSocket daemon running on the operator's remote Linux/macOS host, wrapping documented Antigravity CLI (`agy`) commands (`agy -p ... --output-format stream-json`, `agy remote-control start|stop|status`), safe jailed workspace inspection, git diff, MCP config inspection, and QR code pairing. Includes a built-in simulated `agy` adapter for local testing when `agy` is not installed.

## Users

- **Primary User**: Technical operator controlling a personal or authorized remote Antigravity backend host from an iPhone while away from the desk or switching contexts.
- **Job**: Dispatch prompts, stream agent responses live, trigger frequent slash-command workflows in one tap, monitor or stop remote daemon/runs, inspect workspace files/diffs, and manage host connections securely.

## Product Purpose

Deliver a fast, thumb-ergonomic native iOS control client and self-hosted remote bridge so every Antigravity backend action on a remote machine is reachable in 1–2 taps without fighting a mobile web wrapper or SSH terminal.

## Positioning

Native Apple HIG ergonomics paired with a zero-dependency, verifiable local/LAN/Tailscale bridge: real SwiftUI controls, Keychain-secured pairing, one-tap slash-command deck above the composer, and live WebSocket streaming backed directly by documented `agy` CLI interfaces.

## Operating Context

- Remote host runs Linux or macOS on LAN, VPN, or Tailscale.
- Operator pairs iPhone by scanning a terminal QR code printed by the bridge daemon (or entering host URL + one-time pairing code / bearer token manually).
- Because this build environment runs Linux without Xcode/Swift, the bridge daemon and API/WS tests execute and verify here, while the SwiftUI iOS target builds and runs on macOS Xcode (with full XcodeGen manifest and `#Preview` / Demo host mode).

## Capabilities and Constraints

- **Core Capabilities**:
  - Live agent chat with real-time WebSocket streaming, tool-call activity rows, session switching, and run cancellation.
  - One-tap Quick Slash-Command Deck (`/plan`, `/goal`, `/compact`, `/agents`, `/config`, `/remote-control`, `/diff`, `/test`, `/status`, `/help`) directly above the chat composer plus searchable command sheet.
  - Remote Control Deck for `agy remote-control` daemon (`start`, `stop`, `status`), host health/latency, and live/recent run management.
  - Workspace explorer with project switcher, directory/file viewer, and git status/diff view strictly jailed to configured trusted workspaces.
  - Multi-host manager with QR pairing scanner (just-in-time camera permission explanation), Keychain bearer token storage, model/permission policy editor, MCP server overview, and built-in offline Demo host.
- **Security & Sandbox Constraints**:
  - Uses documented `agy` CLI flags and explicit operator-run bridge only; never probes undocumented host services or bypasses authentication.
  - Auth tokens stored in iOS Keychain (never `UserDefaults`), verified with constant-time comparison on the bridge.
  - Workspace file and git routes strictly validate canonical realpaths inside configured workspace roots.
  - Explicit destructive confirmations for cancelling runs, stopping daemon, or deleting sessions/hosts.

## Product Principles

1. **One-Tap Reach**: Primary actions (send prompt, slash macros, cancel run, switch host, daemon toggle) sit in thumb reach without deep menus.
2. **Native iOS First**: Pure Apple HIG navigation, system semantic colors, Dynamic Type, SF Symbols, standard sheets, and native swipe gestures.
3. **Honest Live State**: Every remote surface shows explicit connecting, streaming, empty, offline, or failed states with immediate retry.
4. **Zero-Friction Pairing, Strict Auth**: Scan-to-pair setup with one-time claim codes, Keychain token storage, and no unauthenticated control routes.
5. **Verifiable Contract**: Shared REST + WebSocket schema between Swift `AntiCore` and Node `bridge` with runnable tests.

## Accessibility & Inclusion

- Full Dynamic Type scaling across standard and Accessibility sizes (no fixed font sizes; adaptive stacking at AX sizes).
- WCAG AA contrast (≥4.5:1 text) in Light Mode, Dark Mode, and Increase Contrast via semantic Apple system colors.
- VoiceOver labels, hints, and traits on every interactive control; 44×44 pt minimum tap targets; Reduce Motion honored throughout.
