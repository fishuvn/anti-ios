import AntiCore
import SwiftUI

struct CommandPaletteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection
    @Environment(ChatStore.self) private var chat
    @Environment(WorkspaceStore.self) private var workspace

    @State private var query = ""

    private var filteredCommands: [SlashCommandItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return chat.slashCommands }
        return chat.slashCommands.filter { item in
            item.command.lowercased().contains(trimmed)
                || item.title.lowercased().contains(trimmed)
                || item.description.lowercased().contains(trimmed)
                || item.category.lowercased().contains(trimmed)
        }
    }

    private var groupedCategories: [(String, [SlashCommandItem])] {
        let grouped = Dictionary(grouping: filteredCommands, by: \.category)
        return grouped.keys.sorted().map { key in
            (key.capitalized, grouped[key] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredCommands.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(groupedCategories, id: \.0) { category, items in
                            Section(category) {
                                ForEach(items) { item in
                                    Button {
                                        let client = connection.makeClient()
                                        let wsID = workspace.activeWorkspace?.id
                                        let haptics = connection.hapticsEnabled
                                        dismiss()
                                        Task {
                                            await chat.triggerSlashCommand(
                                                item,
                                                workspaceID: wsID,
                                                using: client,
                                                hapticsEnabled: haptics
                                            )
                                        }
                                    } label: {
                                        HStack(alignment: .center, spacing: 12) {
                                            Image(systemName: item.symbol)
                                                .font(.title3)
                                                .foregroundStyle(Color.accentColor)
                                                .frame(width: 32)
                                                .accessibilityHidden(true)

                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 8) {
                                                    Text(item.command)
                                                        .font(.headline.monospaced())
                                                        .foregroundStyle(.primary)
                                                    if item.autoSend {
                                                        Text("Instant")
                                                            .font(.caption2.weight(.semibold))
                                                            .foregroundStyle(Color.accentColor)
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                                    }
                                                }
                                                Text(item.description)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Quick Commands")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Filter slash commands")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
