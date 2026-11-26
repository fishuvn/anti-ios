import AntiCore
import SwiftUI

@main
struct AntiRemoteApp: App {
    @State private var connectionStore: ConnectionStore
    @State private var chatStore = ChatStore()
    @State private var controlStore = ControlStore()
    @State private var workspaceStore = WorkspaceStore()
    @State private var tabRouter = TabRouter()
    @State private var selectedTab: AppTab = .chat

    init() {
        #if canImport(Security)
        let repo = HostProfileRepository(tokenStore: KeychainTokenStore())
        #else
        let repo = HostProfileRepository(tokenStore: InMemoryTokenStore())
        #endif
        _connectionStore = State(initialValue: ConnectionStore(repository: repo))
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(selectedTab: $selectedTab)
                .environment(connectionStore)
                .environment(chatStore)
                .environment(controlStore)
                .environment(workspaceStore)
                .environment(tabRouter)
                .tint(.accentColor)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "antiremote" else { return }
        selectedTab = .settings
        tabRouter.router(for: .settings).presentedSheet = .qrPairing(prefillURI: url.absoluteString)
    }
}
