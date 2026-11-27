import AntiCore
import SwiftUI

struct AppShellView: View {
    @Binding var selectedTab: AppTab

    @Environment(ConnectionStore.self) private var connection
    @Environment(ChatStore.self) private var chat
    @Environment(ControlStore.self) private var control
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(TabRouter.self) private var tabRouter

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    tabStack(for: tab)
                }
                .badge(badgeCount(for: tab))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .adaptiveTabBarMinimizeOnScroll()
        .onChange(of: selectedTab) { _, _ in
            HapticManager.shared.fire(.selection, enabled: connection.hapticsEnabled)
        }
        .task(id: connection.activeConnectionKey) {
            await connectAndStream()
        }
    }

    @ViewBuilder
    private func tabStack(for tab: AppTab) -> some View {
        let router = tabRouter.router(for: tab)
        NavigationStack(path: tabRouter.binding(for: tab)) {
            tabRootView(for: tab)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .workspaceDirectory(let wsID, let relPath, let title):
                        DirectoryBrowserView(workspaceID: wsID, relativePath: relPath, title: title)
                    case .filePreview(let wsID, let relPath, let title):
                        FileViewerView(workspaceID: wsID, relativePath: relPath, title: title)
                    }
                }
        }
        .sheet(item: tabRouter.sheetBinding(for: tab)) { destination in
            sheetView(for: destination)
        }
        .environment(router)
    }

    @ViewBuilder
    private func tabRootView(for tab: AppTab) -> some View {
        switch tab {
        case .chat:
            ChatTabView()
        case .control:
            ControlTabView()
        case .workspace:
            WorkspaceTabView()
        case .settings:
            SettingsTabView()
        }
    }

    @ViewBuilder
    private func sheetView(for destination: SheetDestination) -> some View {
        switch destination {
        case .hostSwitcher:
            HostSwitcherSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .addHost:
            AddHostSheet()
        case .qrPairing(let prefillURI):
            QRPairingSheet(prefillURI: prefillURI)
        case .commandPalette:
            CommandPaletteSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .sessionPicker:
            SessionPickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func badgeCount(for tab: AppTab) -> Int {
        switch tab {
        case .control:
            return control.activeRuns.count
        default:
            return 0
        }
    }

    private func connectAndStream() async {
        tabRouter.resetAllPaths()
        chat.reset()
        control.reset()
        workspace.reset()

        let client = connection.makeClient()

        async let connTask: Void = connection.refreshConnection(using: client)
        async let chatTask: Void = chat.loadInitial(using: client)
        async let runsTask: Void = control.refreshRuns(using: client)
        async let wsTask: Void = workspace.loadWorkspaces(using: client)
        _ = await (connTask, chatTask, runsTask, wsTask)

        guard !Task.isCancelled else { return }

        // Maintain live WebSocket event stream with bounded exponential backoff
        var attempt = 0
        var hasConnectedOnce = false
        while !Task.isCancelled {
            do {
                let stream = client.streamEvents()
                for try await event in stream {
                    attempt = 0
                    chat.handleStreamEvent(event)
                    control.handleStreamEvent(event)
                    if case .daemonUpdated(let daemon) = event {
                        connection.applyDaemonUpdate(daemon)
                    } else if case .connected(_, let daemon) = event {
                        if let daemon {
                            connection.applyDaemonUpdate(daemon)
                        }
                        if hasConnectedOnce {
                            await chat.reloadActiveSession(using: client)
                            await control.refreshRuns(using: client)
                        }
                        hasConnectedOnce = true
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                attempt = min(attempt + 1, 5)
            }
            let delaySeconds = min(15, 1 << attempt)
            try? await Task.sleep(for: .seconds(delaySeconds))
        }
    }
}

#Preview("App Shell — Demo Rig") {
    let repo = HostProfileRepository(suiteName: "preview.shell", tokenStore: InMemoryTokenStore())
    AppShellView(selectedTab: .constant(.chat))
        .environment(ConnectionStore(repository: repo))
        .environment(ChatStore())
        .environment(ControlStore())
        .environment(WorkspaceStore())
        .environment(TabRouter())
}
