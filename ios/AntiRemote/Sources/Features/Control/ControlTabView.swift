import AntiCore
import SwiftUI

struct ControlTabView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ControlStore.self) private var control
    @Environment(RouterPath.self) private var router

    @State private var confirmStopDaemon = false
    @State private var runToCancel: AgentRun?

    var body: some View {
        List {
            if let err = control.errorMessage {
                Section {
                    ErrorBannerView(message: err) {
                        Task { await refreshAll() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            hostOverviewSection
            daemonControlSection
            activeRunsSection
            recentRunsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Control")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionStatusPill(
                    hostName: connection.activeHost.name,
                    state: connection.connectionState
                ) {
                    router.presentedSheet = .hostSwitcher
                }
            }
        }
        .refreshable {
            await refreshAll()
        }
        .confirmationDialog(
            "Stop Remote Control Daemon?",
            isPresented: $confirmStopDaemon,
            titleVisibility: .visible
        ) {
            Button("Stop Daemon", role: .destructive) {
                triggerDaemon(.stop)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs `agy remote-control stop` on \(connection.activeHost.name). Active bridge sessions remain reachable.")
        }
        .confirmationDialog(
            "Cancel Active Run?",
            isPresented: Binding(
                get: { runToCancel != nil },
                set: { if !$0 { runToCancel = nil } }
            ),
            presenting: runToCancel
        ) { target in
            Button("Stop Run", role: .destructive) {
                let client = connection.makeClient()
                let haptics = connection.hapticsEnabled
                Task {
                    await control.cancelRun(target.id, using: client, hapticsEnabled: haptics)
                }
            }
            Button("Keep Running", role: .cancel) {}
        } message: { target in
            Text("Stop \"\(target.prompt)\"?")
        }
    }

    @ViewBuilder
    private var hostOverviewSection: some View {
        Section("Remote Host") {
            if let status = connection.hostStatus {
                LabeledContent("Machine", value: status.hostname)
                LabeledContent("Platform", value: status.platform)
                LabeledContent("Adapter", value: status.adapter.uppercased())
                LabeledContent("Antigravity CLI") {
                    if status.agyInstalled {
                        SemanticStatusBadge(
                            title: status.agyVersion ?? "Installed",
                            symbol: "checkmark.circle.fill",
                            tone: .positive
                        )
                    } else {
                        SemanticStatusBadge(title: "Not Found (Mock)", symbol: "wrench", tone: .warning)
                    }
                }
                LabeledContent("Uptime", value: formattedUptime(status.uptimeSeconds))
                LabeledContent("Policy") {
                    Text("\(status.modelProvider) · \(status.permissionMode)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else if case .failed(let msg) = connection.connectionState {
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Reconnect") {
                        connection.reconnect()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading remote host telemetry...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var daemonControlSection: some View {
        Section {
            if let daemon = connection.hostStatus?.daemon {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("agy remote-control")
                            .font(.headline.monospaced())
                        Text(daemon.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    daemonBadge(for: daemon.state)
                }
                .padding(.vertical, 2)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        daemonActionButtons(state: daemon.state)
                    }
                    VStack(spacing: 10) {
                        daemonActionButtons(state: daemon.state)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("Daemon state unavailable until connected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Daemon Lifecycle")
        } footer: {
            Text("Controls the documented `agy remote-control` background daemon on the remote machine.")
        }
    }

    @ViewBuilder
    private func daemonActionButtons(state: DaemonLifecycleState) -> some View {
        Button {
            triggerDaemon(.start)
        } label: {
            Label("Start", systemImage: "play.fill")
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .disabled(control.isDaemonBusy || state == .running)

        Button(role: .destructive) {
            confirmStopDaemon = true
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .disabled(control.isDaemonBusy || state == .stopped)

        Button {
            triggerDaemon(.status)
        } label: {
            Label("Check", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .disabled(control.isDaemonBusy)
    }

    @ViewBuilder
    private var activeRunsSection: some View {
        Section("Active Runs (\(control.activeRuns.count))") {
            if control.activeRuns.isEmpty {
                Label("No tasks currently running", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(control.activeRuns) { run in
                    HStack(alignment: .center, spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.prompt)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text("Started \(run.startedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            runToCancel = run
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Stop run")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentRunsSection: some View {
        Section("Recent Runs") {
            if control.recentRuns.isEmpty {
                Text("Completed and cancelled runs appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(control.recentRuns.prefix(15)) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(run.prompt)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            runStatusBadge(run.status)
                        }
                        HStack(spacing: 12) {
                            Text(run.startedAt, format: .dateTime.hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !run.toolEvents.isEmpty {
                                Text("\(run.toolEvents.count) tool events")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let error = run.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func daemonBadge(for state: DaemonLifecycleState) -> some View {
        switch state {
        case .running:
            SemanticStatusBadge(title: "Running", symbol: "bolt.fill", tone: .positive)
        case .stopped:
            SemanticStatusBadge(title: "Stopped", symbol: "pause.circle", tone: .neutral)
        case .error:
            SemanticStatusBadge(title: "Error", symbol: "exclamationmark.triangle", tone: .negative)
        case .unknown:
            SemanticStatusBadge(title: "Unknown", symbol: "questionmark.circle", tone: .warning)
        }
    }

    private func runStatusBadge(_ status: MessageStatus) -> some View {
        switch status {
        case .completed:
            SemanticStatusBadge(title: "Done", symbol: "checkmark.circle", tone: .positive)
        case .cancelled:
            SemanticStatusBadge(title: "Cancelled", symbol: "stop.circle", tone: .warning)
        case .failed:
            SemanticStatusBadge(title: "Failed", symbol: "xmark.circle", tone: .negative)
        case .streaming:
            SemanticStatusBadge(title: "Live", symbol: "bolt.fill", tone: .positive)
        }
    }

    private func triggerDaemon(_ action: DaemonAction) {
        let client = connection.makeClient()
        let haptics = connection.hapticsEnabled
        Task {
            await control.performDaemonAction(action, using: client, hapticsEnabled: haptics) { updated in
                connection.applyDaemonUpdate(updated)
            }
        }
    }

    private func refreshAll() async {
        let client = connection.makeClient()
        async let c: Void = connection.refreshConnection(using: client)
        async let r: Void = control.refreshRuns(using: client)
        _ = await (c, r)
    }

    private func formattedUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let mins = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(max(1, mins))m"
    }
}

#Preview("Control Tab") {
    let repo = HostProfileRepository(suiteName: "preview.control", tokenStore: InMemoryTokenStore())
    NavigationStack {
        ControlTabView()
    }
    .environment(ConnectionStore(repository: repo))
    .environment(ControlStore())
    .environment(RouterPath())
}
