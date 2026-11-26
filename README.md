# AntiRemote — Native iOS Client & Remote Antigravity Bridge

Control your remote Google Antigravity backend (`agy`) from iPhone with Apple HIG native SwiftUI ergonomics, live WebSocket streaming, one-tap slash commands, workspace/diff inspection, and zero-dependency QR pairing.

## Repository Layout

- `bridge/` — Zero-dependency Node.js (v20+) HTTPS/WSS Remote Bridge daemon wrapping documented `agy` CLI commands (`agy -p ... --output-format stream-json`, `agy remote-control start|stop|status`), jailed workspace file & git inspection, `~/.gemini/antigravity-cli/settings.json` management, and terminal QR pairing.
- `ios/` — Native SwiftUI iOS 18+ app (`Swift 6.0` strict concurrency, `XcodeGen` `project.yml`) + `Packages/AntiCore` Swift Package (`Models`, `KeychainTokenStore`, `HostProfileRepository`, `BridgeClient`, and Swift Testing tests).
- `.github/workflows/ios-ipa-release.yml` & `.github/scripts/generate-vi-changelog.mjs` — GitHub Actions CI/CD that tests Bridge + `AntiCore`, compiles an `.ipa` on `macos-15`, and auto-publishes a GitHub Release with an auto-generated Vietnamese changelog.
- `PRODUCT.md` & `DESIGN.md` — Product truth and Apple HIG design system contract.

## 1. Run the Remote Bridge (Linux / macOS Remote Machine)

Requires Node.js >= 20 (zero `npm install` needed):

```bash
cd bridge
npm test
node ./src/cli.mjs --workspace /path/to/your/project
```

- Automatically uses `agy` when installed on `PATH` (`--adapter auto`), or falls back cleanly to `--adapter mock` for local testing.
- Prints a one-time pairing code and scannable terminal QR code (`antiremote://pair?url=...&code=...`).
- For public/WAN access, place behind Tailscale or pass `--tls-cert cert.pem --tls-key key.pem` for HTTPS/WSS.

## 2. Build & Run the iOS App (macOS + Xcode 16+)

```bash
# Run pure-Swift core unit tests (Swift Testing)
cd ios/Packages/AntiCore
swift test

# Generate Xcode project and open
cd ../..
brew install xcodegen   # once
xcodegen generate
open AntiRemote.xcodeproj
```

1. Select an iPhone simulator (e.g., iPhone SE 3rd gen + iPhone 16 Pro Max) or physical iPhone and press **Run**.
2. The app launches straight into **Demo Rig** so every tab, slash command, streaming response, file viewer, and git diff works immediately without setup.
3. Tap the host pill at the top-left (or **Settings -> Pair Remote Machine via QR**) to scan the terminal QR code printed by `antiremote-bridge`.

## Security Controls

- Bearer tokens stored exclusively in iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and verified with `crypto.timingSafeEqual` on the bridge.
- Pairing codes are single-use, expire after 10 minutes, and rate-limited per IP.
- Workspace file/git routes verify canonical `realpath` boundaries and reject `..` traversal and symlink escapes.
- `NSAppTransportSecurity` allows only local network HTTP (`NSAllowsLocalNetworking = true`), preserving ATS HTTPS enforcement on public hosts.
