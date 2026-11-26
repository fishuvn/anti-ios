import AntiCore
import SwiftUI

struct HostSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection
    @Environment(RouterPath.self) private var router

    var body: some View {
        NavigationStack {
            List {
                Section("Select Remote Host") {
                    ForEach(connection.profiles) { host in
                        Button {
                            connection.selectHost(host.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: host.isDemo ? "cpu" : "server.rack")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(host.hostLabel)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if host.id == connection.activeHost.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button {
                        router.presentedSheet = .qrPairing()
                    } label: {
                        Label("Pair New Machine via QR Code", systemImage: "qrcode.viewfinder")
                    }

                    Button {
                        router.presentedSheet = .addHost
                    } label: {
                        Label("Add Host Manually", systemImage: "plus.circle")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Remote Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
