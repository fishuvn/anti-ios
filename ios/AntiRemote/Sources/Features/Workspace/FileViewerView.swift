import AntiCore
import SwiftUI
import UIKit

struct FileViewerView: View {
    let workspaceID: String
    let relativePath: String
    let title: String

    @Environment(ConnectionStore.self) private var connection

    @State private var preview: FilePreview?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        Group {
            if isLoading && preview == nil {
                ProgressView("Loading \(title)...")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Unable to Read File", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") {
                        Task { await load() }
                    }
                    .adaptiveGlassProminentButton()
                }
            } else if let preview {
                if preview.isBinary {
                    ContentUnavailableView(
                        "Binary File",
                        systemImage: "doc.zipper",
                        description: Text("\(preview.path) (\(ByteCountFormatter.string(fromByteCount: Int64(preview.size), countStyle: .file))) cannot be rendered as UTF-8 text.")
                    )
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 10) {
                            if preview.truncated {
                                Label("Showing first 256 KB of file", systemImage: "info.circle")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                            Text(preview.content.isEmpty ? "(Empty file)" : preview.content)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                    }
                    .background(Color(.systemBackground))
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let content = preview?.content, !content.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = content
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copy file contents")

                    ShareLink(item: content, subject: Text(title))
                }
            }
        }
        .task(id: relativePath) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            preview = try await connection.makeClient().readFile(workspaceID, relativePath)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
