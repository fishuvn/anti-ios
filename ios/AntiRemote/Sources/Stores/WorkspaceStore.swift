import AntiCore
import Foundation
import os

@MainActor
@Observable
final class WorkspaceStore {
    private static let logger = Logger(subsystem: "com.antiremote.app", category: "workspace")

    var workspaces: [WorkspaceInfo] = []
    var selectedWorkspaceID: String?
    var rootListing: DirectoryListing?
    var gitDetail: GitDetail?
    var isLoading = false
    var errorMessage: String?

    var activeWorkspace: WorkspaceInfo? {
        if let id = selectedWorkspaceID, let match = workspaces.first(where: { $0.id == id }) {
            return match
        }
        return workspaces.first
    }

    func reset() {
        workspaces = []
        selectedWorkspaceID = nil
        rootListing = nil
        gitDetail = nil
        isLoading = false
        errorMessage = nil
    }

    func loadWorkspaces(using client: BridgeClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let list = try await client.workspaces()
            guard !Task.isCancelled else { return }
            workspaces = list
            if selectedWorkspaceID == nil || !list.contains(where: { $0.id == selectedWorkspaceID }) {
                selectedWorkspaceID = list.first?.id
            }
            if let wsID = activeWorkspace?.id {
                await loadWorkspaceContent(workspaceID: wsID, using: client)
            }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Workspace load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func selectWorkspace(_ id: String, using client: BridgeClient) async {
        selectedWorkspaceID = id
        await loadWorkspaceContent(workspaceID: id, using: client)
    }

    func loadWorkspaceContent(workspaceID: String, using client: BridgeClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let listingTask = client.listFiles(workspaceID, "")
            async let gitTask = client.gitDetail(workspaceID)
            let (listing, git) = try await (listingTask, gitTask)
            guard !Task.isCancelled else { return }
            rootListing = listing
            gitDetail = git
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
