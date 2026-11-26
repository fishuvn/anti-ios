import AntiCore
import SwiftUI

struct WorkspaceTabView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case files = "Files"
        case git = "Git Diff"
        var id: String { rawValue }
    }

    @Environment(ConnectionStore.self) private var connection
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(RouterPath.self) private var router

    @State private var mode: Mode = .files

    var body: some View {
        Group {
            if workspace.workspaces.isEmpty && !workspace.isLoading {
                ContentUnavailableView {
                    Label("No Workspaces", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(workspace.errorMessage ?? "Configure `--workspace <path>` when starting the remote bridge.")
                } actions: {
                    Button("Reload") {
                        Task { await workspace.loadWorkspaces(using: connection.makeClient()) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if let err = workspace.errorMessage {
                        Section {
                            ErrorBannerView(message: err) {
                                Task { await workspace.loadWorkspaces(using: connection.makeClient()) }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }

                    Section {
                        Picker("Workspace View", selection: $mode) {
                            ForEach(Mode.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }

                    if let active = workspace.activeWorkspace {
                        workspaceSummarySection(active)

                        if mode == .files {
                            filesSection(workspaceID: active.id, entries: workspace.rootListing?.entries ?? [])
                        } else {
                            gitDiffSection(workspace.gitDetail)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(workspace.activeWorkspace?.name ?? "Workspace")
        .toolbar {
            if workspace.workspaces.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(workspace.workspaces) { ws in
                            Button {
                                let client = connection.makeClient()
                                Task { await workspace.selectWorkspace(ws.id, using: client) }
                            } label: {
                                Label(
                                    ws.name,
                                    systemImage: ws.id == workspace.activeWorkspace?.id ? "checkmark" : "folder"
                                )
                            }
                        }
                    } label: {
                        Label("Switch", systemImage: "folder.badge.gearshape")
                    }
                }
            }
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
            await workspace.loadWorkspaces(using: connection.makeClient())
        }
    }

    private func workspaceSummarySection(_ ws: WorkspaceInfo) -> some View {
        Section("Active Project") {
            LabeledContent("Path") {
                Text(ws.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if ws.isGitRepo {
                LabeledContent("Branch") {
                    HStack(spacing: 6) {
                        Text(ws.branch ?? "HEAD")
                            .font(.subheadline.monospaced().weight(.medium))
                        if ws.dirtyCount > 0 {
                            SemanticStatusBadge(title: "\(ws.dirtyCount) changed", symbol: "pencil", tone: .warning)
                        } else {
                            SemanticStatusBadge(title: "Clean", symbol: "checkmark", tone: .positive)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filesSection(workspaceID: String, entries: [FileEntry]) -> some View {
        Section("Files") {
            if workspace.isLoading && entries.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading files...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if entries.isEmpty {
                Text("Directory is empty.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    FileEntryRow(entry: entry) {
                        if entry.isDirectory {
                            router.navigate(to: .workspaceDirectory(
                                workspaceID: workspaceID,
                                relativePath: entry.path,
                                title: entry.name
                            ))
                        } else {
                            router.navigate(to: .filePreview(
                                workspaceID: workspaceID,
                                relativePath: entry.path,
                                title: entry.name
                            ))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gitDiffSection(_ detail: GitDetail?) -> some View {
        if let detail {
            if !detail.isGitRepo {
                Section("Git") {
                    Label("Not a git repository", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Changed Files (\(detail.changedFiles.count))") {
                    if detail.changedFiles.isEmpty {
                        Label("Working tree clean", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(detail.changedFiles) { item in
                            HStack(spacing: 10) {
                                Text(item.status)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(statusColor(item.status))
                                    .frame(width: 24)
                                Text(item.path)
                                    .font(.footnote.monospaced())
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                if !detail.diff.isEmpty {
                    Section("Unified Diff") {
                        ScrollView(.horizontal, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(detail.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, rawLine in
                                    let line = String(rawLine)
                                    Text(line.isEmpty ? " " : line)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(diffLineColor(line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 4)
                                        .background(diffLineBackground(line))
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .textSelection(.enabled)
                    }
                }
            }
        } else {
            Section("Git") {
                ProgressView()
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        if status.contains("A") || status.contains("?") { return .green }
        if status.contains("D") { return .red }
        return .orange
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return Color.accentColor }
        return .primary
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.10) }
        return .clear
    }
}

struct DirectoryBrowserView: View {
    let workspaceID: String
    let relativePath: String
    let title: String

    @Environment(ConnectionStore.self) private var connection
    @Environment(RouterPath.self) private var router

    @State private var listing: DirectoryListing?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                ErrorBannerView(message: errorMessage) {
                    Task { await load() }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if isLoading && listing == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading directory...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let entries = listing?.entries {
                if entries.isEmpty {
                    Text("Folder is empty.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        FileEntryRow(entry: entry) {
                            if entry.isDirectory {
                                router.navigate(to: .workspaceDirectory(
                                    workspaceID: workspaceID,
                                    relativePath: entry.path,
                                    title: entry.name
                                ))
                            } else {
                                router.navigate(to: .filePreview(
                                    workspaceID: workspaceID,
                                    relativePath: entry.path,
                                    title: entry.name
                                ))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: relativePath) {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            listing = try await connection.makeClient().listFiles(workspaceID, relativePath)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FileEntryRow: View {
    let entry: FileEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.isDirectory ? "Opens folder." : "Opens file viewer.")
    }
}
