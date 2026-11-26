import AntiCore
import SwiftUI
import UIKit

struct SettingsTabView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(RouterPath.self) private var router

    @State private var hostToDelete: HostProfile?

    private let modelProviders = ["gemini", "vertex", "anthropic", "openai-compatible", "default"]
    private let permissionModes = ["ask", "allow-read", "strict"]

    var body: some View {
        @Bindable var bindableConn = connection

        Form {
            Section("Quick Pair & Connect") {
                Button {
                    router.presentedSheet = .qrPairing()
                } label: {
                    Label("Pair Remote Machine via QR", systemImage: "qrcode.viewfinder")
                }

                Button {
                    router.presentedSheet = .addHost
                } label: {
                    Label("Add Host Manually", systemImage: "plus.circle")
                }

                if !connection.activeHost.isDemo && connection.connectionState.isConnected {
                    Button {
                        let client = connection.makeClient()
                        Task { await connection.generatePairingCode(using: client) }
                    } label: {
                        Label("Generate Pairing Code for Another Device", systemImage: "key.radiowaves.forward")
                    }
                }

                if let share = connection.lastPairingShare {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("One-Time Code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(share.code)
                                .font(.headline.monospaced())
                        }
                        HStack {
                            Text("Expires \(share.expiresAt.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy URI") {
                                UIPasteboard.general.string = share.pairingURI
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Saved Remote Hosts") {
                ForEach(connection.profiles) { host in
                    Button {
                        connection.selectHost(host.id)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(host.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(host.hostLabel)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if host.id == connection.activeHost.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !host.isDemo {
                            Button(role: .destructive) {
                                hostToDelete = host
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if let settings = connection.remoteSettings {
                Section {
                    Picker(
                        "Model Provider",
                        selection: Binding(
                            get: { settings.modelProvider },
                            set: { newVal in
                                let client = connection.makeClient()
                                Task { await connection.updateRemoteSettings(using: client, modelProvider: newVal) }
                            }
                        )
                    ) {
                        ForEach(modelProviders, id: \.self) { provider in
                            Text(provider).tag(provider)
                        }
                    }
                    .disabled(connection.isUpdatingSettings)

                    Picker(
                        "Permission Policy",
                        selection: Binding(
                            get: { settings.permissionMode },
                            set: { newVal in
                                let client = connection.makeClient()
                                Task { await connection.updateRemoteSettings(using: client, permissionMode: newVal) }
                            }
                        )
                    ) {
                        ForEach(permissionModes, id: \.self) { mode in
                            Text(mode).tag(mode)
                        }
                    }
                    .disabled(connection.isUpdatingSettings)

                    LabeledContent("Config Path") {
                        Text(settings.configPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Antigravity CLI Settings")
                } footer: {
                    Text("Syncs validated fields with ~/.gemini/antigravity-cli/settings.json on the remote host.")
                }

                Section("MCP Servers (\(settings.mcpServers.count))") {
                    if settings.mcpServers.isEmpty {
                        Text("No MCP servers detected in active workspace or user config.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.mcpServers) { server in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.name)
                                        .font(.body.weight(.medium))
                                    Text("\(server.transport) · \(server.target)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                SemanticStatusBadge(
                                    title: server.enabled ? "Enabled" : "Disabled",
                                    symbol: server.enabled ? "checkmark.circle" : "slash.circle",
                                    tone: server.enabled ? .positive : .neutral
                                )
                            }
                        }
                    }
                }
            }

            if let err = connection.settingsError {
                Section {
                    ErrorBannerView(message: err)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("App Preferences") {
                Toggle("Haptic Feedback", isOn: $bindableConn.hapticsEnabled)
                LabeledContent("Connection", value: connection.connectionState.label)
                Button("Reconnect Now") {
                    connection.reconnect()
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Remove Host?",
            isPresented: Binding(
                get: { hostToDelete != nil },
                set: { if !$0 { hostToDelete = nil } }
            ),
            presenting: hostToDelete
        ) { target in
            Button("Remove \"\(target.name)\"", role: .destructive) {
                connection.removeHost(target.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deletes the saved host profile and removes its bearer token from Keychain.")
        }
    }
}

#Preview("Settings Tab") {
    let repo = HostProfileRepository(suiteName: "preview.settings", tokenStore: InMemoryTokenStore())
    NavigationStack {
        SettingsTabView()
    }
    .environment(ConnectionStore(repository: repo))
    .environment(RouterPath())
}
