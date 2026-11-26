import AntiCore
import SwiftUI

struct SessionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection
    @Environment(ChatStore.self) private var chat
    @Environment(WorkspaceStore.self) private var workspace

    @State private var sessionToDelete: SessionSummary?

    var body: some View {
        NavigationStack {
            List {
                if chat.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Create a session to start controlling the remote Antigravity host.")
                    )
                } else {
                    ForEach(chat.sessions) { session in
                        Button {
                            let client = connection.makeClient()
                            dismiss()
                            Task {
                                await chat.selectSession(session.id, using: client)
                            }
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(session.title)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if session.activeRunId != nil {
                                            SemanticStatusBadge(title: "Live", symbol: "bolt.fill", tone: .positive)
                                        }
                                    }
                                    Text(session.lastPreview)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text("\(session.messageCount) messages · \(session.updatedAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if chat.activeSession?.id == session.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                sessionToDelete = session
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let client = connection.makeClient()
                        let wsID = workspace.activeWorkspace?.id
                        dismiss()
                        Task {
                            await chat.createSession(title: "New Session", workspaceID: wsID, using: client)
                        }
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }
                }
            }
            .confirmationDialog(
                "Delete Session?",
                isPresented: Binding(
                    get: { sessionToDelete != nil },
                    set: { if !$0 { sessionToDelete = nil } }
                ),
                presenting: sessionToDelete
            ) { target in
                Button("Delete \"\(target.title)\"", role: .destructive) {
                    let client = connection.makeClient()
                    Task {
                        await chat.deleteSession(target.id, using: client)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently removes the session history on the remote bridge.")
            }
        }
    }
}
