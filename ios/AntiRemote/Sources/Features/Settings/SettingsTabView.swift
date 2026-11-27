import AntiCore
import SwiftUI
import UIKit

struct SettingsTabView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(RouterPath.self) private var router

    @State private var hostToDelete: HostProfile?

    private let agentModes: [(id: String, label: String)] = [
        ("default", "Inherit CLI Default"),
        ("plan", "Plan (Read-Only)"),
        ("accept-edits", "Accept Edits"),
        ("auto", "Auto"),
    ]

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
                        "Model Override",
                        selection: Binding(
                            get: { settings.selectedModel },
                            set: { newVal in
                                guard newVal != settings.selectedModel else { return }
                                let client = connection.makeClient()
                                Task { await connection.updateRemoteSettings(using: client, selectedModel: newVal) }
                            }
                        )
                    ) {
                        Text(settings.cliDefaultModel.map { "Inherit CLI (\($0))" } ?? "Inherit CLI Default")
                            .tag("default")
                        ForEach(settings.availableModels) { model in
                            Text(model.label).tag(model.id)
                        }
                        if settings.selectedModel != "default",
                           !settings.availableModels.contains(where: { $0.id == settings.selectedModel }) {
                            Text(settings.selectedModel).tag(settings.selectedModel)
                        }
                    }
                    .disabled(connection.isUpdatingSettings)

                    Picker(
                        "Agent Mode",
                        selection: Binding(
                            get: { settings.agentMode },
                            set: { newVal in
                                guard newVal != settings.agentMode else { return }
                                let client = connection.makeClient()
                                Task { await connection.updateRemoteSettings(using: client, agentMode: newVal) }
                            }
                        )
                    ) {
                        ForEach(agentModes, id: \.id) { mode in
                            if mode.id == "default", let cliMode = settings.cliAgentMode {
                                Text("Inherit CLI (\(cliMode))").tag(mode.id)
                            } else {
                                Text(mode.label).tag(mode.id)
                            }
                        }
                    }
                    .disabled(connection.isUpdatingSettings)

                    LabeledContent("CLI Config (Read-Only)") {
                        Text(settings.configPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("Remote Run Overrides")
                } footer: {
                    Text("Overrides apply per remote run via --model / --mode. AntiBridge never modifies ~/.gemini/antigravity-cli/settings.json.")
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
                LabeledContent("Interface", value: AdaptiveInterfaceStyle.displayName)
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
