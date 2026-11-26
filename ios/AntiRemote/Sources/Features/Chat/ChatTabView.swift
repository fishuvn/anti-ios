import AntiCore
import SwiftUI

struct ChatTabView: View {
    @Environment(ConnectionStore.self) private var connection
    @Environment(ChatStore.self) private var chat
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(RouterPath.self) private var router

    @FocusState private var isComposerFocused: Bool
    @State private var confirmCancelRun = false

    var body: some View {
        @Bindable var bindableChat = chat

        ScrollViewReader { proxy in
            Group {
                switch chat.state {
                case .idle, .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting to \(connection.activeHost.name)...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView {
                        Label("Host Unreachable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") {
                            connection.reconnect()
                        }
                        .adaptiveGlassProminentButton()

                        Button("Switch Host") {
                            router.presentedSheet = .hostSwitcher
                        }
                        .adaptiveGlassButton()
                    }

                case .loaded:
                    messageScrollList(proxy: proxy)
                }
            }
            .background(Color(.systemGroupedBackground))
            .adaptiveTopSafeAreaBar {
                if chat.state == .loaded, let ws = workspace.activeWorkspace {
                    workspaceContextStrip(ws)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ComposerBarView(
                    text: $bindableChat.composerText,
                    quickCommands: chat.slashCommands,
                    isStreaming: chat.activeRunID != nil,
                    isSending: chat.isSending,
                    isDisabled: chat.state != .loaded,
                    isFocused: $isComposerFocused,
                    onSend: {
                        let client = connection.makeClient()
                        let wsID = workspace.activeWorkspace?.id
                        let haptics = connection.hapticsEnabled
                        Task {
                            await chat.sendCurrentComposer(
                                workspaceID: wsID,
                                using: client,
                                hapticsEnabled: haptics
                            )
                        }
                    },
                    onStop: {
                        confirmCancelRun = true
                    },
                    onTriggerCommand: { item in
                        let client = connection.makeClient()
                        let wsID = workspace.activeWorkspace?.id
                        let haptics = connection.hapticsEnabled
                        Task {
                            await chat.triggerSlashCommand(
                                item,
                                workspaceID: wsID,
                                using: client,
                                hapticsEnabled: haptics
                            )
                        }
                        if !item.autoSend {
                            isComposerFocused = true
                        }
                    },
                    onOpenPalette: {
                        router.presentedSheet = .commandPalette
                    }
                )
            }
            .navigationTitle(chat.activeSession?.title ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionStatusPill(
                        hostName: connection.activeHost.name,
                        state: connection.connectionState
                    ) {
                        router.presentedSheet = .hostSwitcher
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        router.presentedSheet = .sessionPicker
                    } label: {
                        Image(systemName: "tray.full")
                    }
                    .accessibilityLabel("Switch session")

                    Button {
                        let client = connection.makeClient()
                        let wsID = workspace.activeWorkspace?.id
                        Task {
                            await chat.createSession(title: "New Session", workspaceID: wsID, using: client)
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New session")
                }
            }
            .confirmationDialog(
                "Stop Remote Run?",
                isPresented: $confirmCancelRun,
                titleVisibility: .visible
            ) {
                Button("Stop Active Run", role: .destructive) {
                    let client = connection.makeClient()
                    let haptics = connection.hapticsEnabled
                    Task {
                        await chat.cancelActiveRun(using: client, hapticsEnabled: haptics)
                    }
                }
                Button("Keep Running", role: .cancel) {}
            } message: {
                Text("This sends SIGTERM to the running Antigravity CLI task on \(connection.activeHost.name).")
            }
        }
    }

    @ViewBuilder
    private func messageScrollList(proxy: ScrollViewProxy) -> some View {
        let messages = chat.activeSession?.messages ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let err = chat.errorMessage {
                    ErrorBannerView(message: err) {
                        chat.errorMessage = nil
                    }
                }

                if !AdaptiveInterfaceStyle.isLiquidGlassActive, let ws = workspace.activeWorkspace {
                    workspaceContextStrip(ws)
                }

                if messages.isEmpty {
                    emptyConversationView
                } else {
                    ForEach(messages) { msg in
                        MessageBubbleView(message: msg)
                            .id(msg.id)
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .id("chat-bottom-anchor")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            let client = connection.makeClient()
            if let id = chat.activeSession?.id {
                await chat.selectSession(id, using: client)
            } else {
                await chat.loadInitial(using: client)
            }
        }
        .onChange(of: messages.last?.content) { _, _ in
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
            }
        }
        .onChange(of: messages.count) { _, _ in
            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
        }
    }

    private func workspaceContextStrip(_ ws: WorkspaceInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(ws.name)
                .font(.caption.weight(.semibold))
            if let branch = ws.branch {
                Text(branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let status = connection.hostStatus {
                Text(status.adapter.uppercased())
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlassSurface(
            in: Capsule(),
            interactive: false,
            fallbackBackground: Color(.secondarySystemGroupedBackground)
        )
        .accessibilityElement(children: .combine)
    }

    private var emptyConversationView: some View {
        ContentUnavailableView {
            Label("Ready for Instructions", systemImage: "terminal")
        } description: {
            Text("Send a prompt below or tap any slash command chip to steer Antigravity remotely.")
        }
        .padding(.top, 36)
    }
}

#Preview("Chat Tab — Demo") {
    let repo = HostProfileRepository(suiteName: "preview.chat", tokenStore: InMemoryTokenStore())
    NavigationStack {
        ChatTabView()
    }
    .environment(ConnectionStore(repository: repo))
    .environment(ChatStore())
    .environment(WorkspaceStore())
    .environment(RouterPath())
}
