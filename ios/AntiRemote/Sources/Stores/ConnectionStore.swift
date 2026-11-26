import AntiCore
import Foundation
import os

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(latencyMs: Int)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Connecting"
        case .connected(let ms): "Connected · \(ms) ms"
        case .failed: "Connection Failed"
        }
    }

    var shortLabel: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Connecting"
        case .connected: "Live"
        case .failed: "Error"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
@Observable
final class ConnectionStore {
    private static let logger = Logger(subsystem: "com.antiremote.app", category: "connection")
    private static let hapticsKey = "antiremote.hapticsEnabled.v1"

    private let repository: HostProfileRepository

    var profiles: [HostProfile]
    var selectedHostID: UUID
    var connectionState: ConnectionState = .disconnected
    var hostStatus: HostStatus?
    var remoteSettings: RemoteSettings?
    var lastPairingShare: PairingCreateResponse?
    var isUpdatingSettings = false
    var settingsError: String?
    var reconnectNonce = 0
    var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: Self.hapticsKey)
        }
    }

    init(repository: HostProfileRepository) {
        self.repository = repository
        let loaded = repository.loadProfiles()
        self.profiles = loaded
        let fallbackID = loaded.first?.id ?? HostProfile.demoID
        let savedSelected = repository.loadSelectedHostID(fallback: fallbackID)
        self.selectedHostID = loaded.contains(where: { $0.id == savedSelected }) ? savedSelected : fallbackID
        if UserDefaults.standard.object(forKey: Self.hapticsKey) == nil {
            self.hapticsEnabled = true
        } else {
            self.hapticsEnabled = UserDefaults.standard.bool(forKey: Self.hapticsKey)
        }
    }

    var activeHost: HostProfile {
        profiles.first(where: { $0.id == selectedHostID }) ?? profiles.first ?? .demo
    }

    var activeConnectionKey: String {
        "\(activeHost.id.uuidString)-\(reconnectNonce)"
    }

    func makeClient() -> BridgeClient {
        let host = activeHost
        if host.isDemo {
            return .demo()
        }
        guard let url = host.baseURL else {
            return .demo()
        }
        let token = repository.token(for: host.id)
        return .live(baseURL: url, token: token)
    }

    func selectHost(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedHostID = id
        repository.saveSelectedHostID(id)
        hostStatus = nil
        remoteSettings = nil
        lastPairingShare = nil
        settingsError = nil
        connectionState = .connecting
        HapticManager.shared.fire(.selection, enabled: hapticsEnabled)
    }

    func reconnect() {
        reconnectNonce += 1
    }

    func refreshConnection(using client: BridgeClient) async {
        connectionState = .connecting
        let start = ContinuousClock.now
        do {
            async let statusTask = client.status()
            async let settingsTask = client.settings()
            let (status, settings) = try await (statusTask, settingsTask)
            guard !Task.isCancelled else { return }
            let elapsed = ContinuousClock.now - start
            let ms = max(1, Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
            hostStatus = status
            remoteSettings = settings
            settingsError = nil
            connectionState = .connected(latencyMs: ms)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Host refresh failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .failed(error.localizedDescription)
        }
    }

    func applyDaemonUpdate(_ daemon: DaemonStatus) {
        guard let current = hostStatus else { return }
        hostStatus = HostStatus(
            hostname: current.hostname,
            platform: current.platform,
            uptimeSeconds: current.uptimeSeconds,
            serverVersion: current.serverVersion,
            adapter: current.adapter,
            agyInstalled: current.agyInstalled,
            agyVersion: current.agyVersion,
            daemon: daemon,
            activeRunsCount: current.activeRunsCount,
            workspacesCount: current.workspacesCount,
            modelProvider: current.modelProvider,
            permissionMode: current.permissionMode
        )
    }

    /// Pairs a new remote host via scanned/pasted `antiremote://pair?...` URI.
    func pairHost(from uri: String) async throws -> HostProfile {
        let payload = try PairingPayload.parse(uri: uri)
        let pairingClient = BridgeClient.live(baseURL: payload.baseURL, token: nil)
        let claimed = try await pairingClient.claimPairing(payload.code)

        let host = HostProfile(
            name: payload.hostName.isEmpty ? claimed.hostName : payload.hostName,
            baseURLString: payload.baseURL.absoluteString,
            tlsFingerprint: payload.tlsFingerprint,
            isDemo: false
        )
        profiles = try repository.upsert(profile: host, token: claimed.token)
        selectHost(host.id)
        HapticManager.shared.fire(.success, enabled: hapticsEnabled)
        return host
    }

    /// Adds a host using either a one-time pairing code or an explicit bearer token.
    func addManualHost(name: String, urlString: String, pairingCode: String?, bearerToken: String?) async throws -> HostProfile {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil
        else {
            throw BridgeError.invalidURL(trimmedURL)
        }

        let resolvedToken: String
        var resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let code = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            let client = BridgeClient.live(baseURL: url, token: nil)
            let claimed = try await client.claimPairing(code.uppercased())
            resolvedToken = claimed.token
            if resolvedName.isEmpty {
                resolvedName = claimed.hostName
            }
        } else if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            let client = BridgeClient.live(baseURL: url, token: token)
            let status = try await client.status()
            resolvedToken = token
            if resolvedName.isEmpty {
                resolvedName = status.hostname
            }
        } else {
            throw BridgeError.unauthorized
        }

        let host = HostProfile(
            name: resolvedName.isEmpty ? (url.host ?? "Remote Host") : resolvedName,
            baseURLString: url.absoluteString,
            isDemo: false
        )
        profiles = try repository.upsert(profile: host, token: resolvedToken)
        selectHost(host.id)
        HapticManager.shared.fire(.success, enabled: hapticsEnabled)
        return host
    }

    func removeHost(_ hostID: UUID) {
        do {
            profiles = try repository.remove(hostID: hostID)
            if selectedHostID == hostID, let first = profiles.first {
                selectHost(first.id)
            }
            HapticManager.shared.fire(.warning, enabled: hapticsEnabled)
        } catch {
            Self.logger.error("Failed to remove host: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateRemoteSettings(
        using client: BridgeClient,
        modelProvider: String? = nil,
        permissionMode: String? = nil
    ) async {
        isUpdatingSettings = true
        settingsError = nil
        defer { isUpdatingSettings = false }
        do {
            let updated = try await client.updateSettings(
                RemoteSettingsPatch(modelProvider: modelProvider, permissionMode: permissionMode)
            )
            remoteSettings = updated
            if let current = hostStatus {
                hostStatus = HostStatus(
                    hostname: current.hostname,
                    platform: current.platform,
                    uptimeSeconds: current.uptimeSeconds,
                    serverVersion: current.serverVersion,
                    adapter: current.adapter,
                    agyInstalled: current.agyInstalled,
                    agyVersion: current.agyVersion,
                    daemon: current.daemon,
                    activeRunsCount: current.activeRunsCount,
                    workspacesCount: current.workspacesCount,
                    modelProvider: updated.modelProvider,
                    permissionMode: updated.permissionMode
                )
            }
            HapticManager.shared.fire(.success, enabled: hapticsEnabled)
        } catch {
            settingsError = error.localizedDescription
            HapticManager.shared.fire(.error, enabled: hapticsEnabled)
        }
    }

    func generatePairingCode(using client: BridgeClient) async {
        settingsError = nil
        do {
            lastPairingShare = try await client.createPairingCode()
            HapticManager.shared.fire(.lightImpact, enabled: hapticsEnabled)
        } catch {
            settingsError = error.localizedDescription
            HapticManager.shared.fire(.error, enabled: hapticsEnabled)
        }
    }
}
