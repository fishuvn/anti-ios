# Design System — AntiRemote (iOS)

## Platform & HIG Contract

AntiRemote is a native iOS 18+ SwiftUI application built strictly on Apple Human Interface Guidelines (`ios-screens`, `hig-foundations`, `hig-components-layout`, `hig-patterns`).

- **Navigation Architecture**: 4 peer top-level tabs inside `TabView` (`Tab(value:)` API, `.tabViewStyle(.sidebarAdaptable)` for iPad adaptation), each owning an independent `NavigationStack(path:)` via `TabRouter` and centralized enum-driven `.sheet(item:)`:
  1. **Chat** (`bubble.left.and.text.bubble.right`) — Live streaming agent conversation, nav-bar session/host menu, bottom-anchored composer (`.safeAreaInset(edge: .bottom)`), and one-tap **Quick Slash-Command Deck**.
  2. **Control** (`slider.horizontal.3`) — Host telemetry, `agy remote-control` daemon Start/Stop/Refresh controls, active run monitor with one-tap Cancel, and recent run history.
  3. **Workspace** (`folder`) — Trusted workspace picker, directory/file browser with monospaced code sheet/detail, and git status + unified diff inspector.
  4. **Settings** (`gear`) — Multi-host profiles, QR Pairing scanner, model & permission policy editor (`settings.json`), MCP servers (`mcp_config.json`), haptics toggle, and connection diagnostics.
- **No Anti-Patterns**: No hamburger menus, no custom navigation bars replacing `NavigationStack`, no web-style footers, no nested cards, no gradient text, no eyebrow/kicker labels above headings, no emojis standing in for SF Symbols.

## Color & Materials

- **Surfaces**: Semantic system colors exclusively (`Color(.systemBackground)`, `Color(.secondarySystemBackground)`, `Color(.systemGroupedBackground)`, `Color(.secondarySystemGroupedBackground)`).
- **Text**: `.primary`, `.secondary`, `.tertiary` (automatic Light, Dark, and Increased Contrast compliance ≥4.5:1).
- **Single Interactive Tint**: `AccentColor` asset — deep cobalt indigo (`#1D4ED8` light / `#60A5FA` dark, high-contrast variants `#1E3A8A` / `#93C5FD`) driving interactive buttons, active tab, and focus states.
- **Semantic Status Colors**: System `.green` (connected / running / added diff), `.orange` (connecting / modified / ask policy), `.red` (disconnected / failed / destructive / removed diff), `.secondary` (idle / stopped). Status is NEVER conveyed by color alone — always paired with SF Symbol + text label.
- **Materials**: `.bar` and `.ultraThinMaterial` for bottom composer bar and pinned status chrome only.

## Typography & Dynamic Type

- **UI Font**: San Francisco (`SF Pro`) via semantic SwiftUI text styles ONLY (`.largeTitle`, `.title2`, `.title3`, `.headline`, `.body`, `.callout`, `.subheadline`, `.footnote`, `.caption`, `.caption2`). Zero hard-coded point sizes.
- **Code, Paths, Diffs & Commands**: `.font(.footnote.monospaced())` / `.font(.callout.monospaced())` strictly for actual code, file paths, diffs, slash commands, and telemetry numerals (`.monospacedDigit()`).
- **Accessibility Scaling**: Layouts use `ViewThatFits` or `@Environment(\.dynamicTypeSize)` to stack horizontal key-value rows vertically at `.accessibility1` and above.

## Layout, Touch & Modality

- **Touch Targets**: Every tappable button, chip, and icon action enforces `.frame(minWidth: 44, minHeight: 44)` or full-row `List` hit area.
- **Lists & Forms**: Inset-grouped `List` / `Form` for Control, Workspace, and Settings; `ScrollView` + `LazyVStack` for Chat with `.scrollDismissesKeyboard(.interactively)`.
- **Modality**:
  - `.sheet(item:)` for Host Switcher, QR Scanner, New Host, Command Palette, Session Picker, and Pairing Info — always with standard Cancel (top-left) and confirming action (top-right), owning `dismiss()` internally.
  - `.confirmationDialog` for destructive actions (Stop Daemon, Cancel Run, Delete Session, Remove Host).
  - Just-in-time camera rationale screen inside QR Scanner sheet BEFORE invoking `AVCaptureDevice.requestAccess(for: .video)`.

## Motion & Haptics

- **Motion**: Standard system NavigationStack pushes and sheet transitions. Custom animations limited to subtle streaming pulse and composer send state; wrapped with `@Environment(\.accessibilityReduceMotion)` fallback to opacity crossfade or static indicator.
- **Haptics**: Centralized `HapticManager` gated by user preference (`hapticsEnabled`, default `true`). Fires only on meaningful events: message sent, command triggered, connection succeeded, destructive action confirmed, error surfaced.
