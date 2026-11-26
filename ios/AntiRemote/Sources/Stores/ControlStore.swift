import AntiCore
import Foundation
import os

@MainActor
@Observable
final class ControlStore {
    private static let logger = Logger(subsystem: "com.antiremote.app", category: "control")

    var runs: [AgentRun] = []
    var isLoading = false
    var isDaemonBusy = false
    var errorMessage: String?

    var activeRuns: [AgentRun] {
        runs.filter { $0.status == .streaming }
    }

    var recentRuns: [AgentRun] {
        runs.filter { $0.status != .streaming }
    }

    func reset() {
        runs = []
        isLoading = false
        isDaemonBusy = false
        errorMessage = nil
    }

    func refreshRuns(using client: BridgeClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            runs = try await client.runs()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Failed to fetch runs: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func performDaemonAction(
        _ action: DaemonAction,
        using client: BridgeClient,
        hapticsEnabled: Bool,
        onUpdated: (DaemonStatus) -> Void
    ) async {
        isDaemonBusy = true
        errorMessage = nil
        defer { isDaemonBusy = false }
        do {
            let status = try await client.daemonControl(action)
            onUpdated(status)
            HapticManager.shared.fire(action == .stop ? .warning : .success, enabled: hapticsEnabled)
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.shared.fire(.error, enabled: hapticsEnabled)
        }
    }

    func cancelRun(_ runID: String, using client: BridgeClient, hapticsEnabled: Bool) async {
        errorMessage = nil
        do {
            let updated = try await client.cancelRun(runID)
            if let idx = runs.firstIndex(where: { $0.id == updated.id }) {
                runs[idx] = updated
            }
            HapticManager.shared.fire(.warning, enabled: hapticsEnabled)
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.shared.fire(.error, enabled: hapticsEnabled)
        }
    }

    func handleStreamEvent(_ event: BridgeStreamEvent) {
        switch event {
        case .runStarted(let runID, let sessionID, let messageID, let prompt):
            if !runs.contains(where: { $0.id == runID }) {
                runs.insert(
                    AgentRun(
                        id: runID,
                        sessionId: sessionID,
                        workspaceId: "",
                        assistantMessageId: messageID,
                        prompt: prompt,
                        status: .streaming,
                        startedAt: Date()
                    ),
                    at: 0
                )
            }
        case .toolEvent(let runID, _, _, let tool):
            if let idx = runs.firstIndex(where: { $0.id == runID }) {
                if let tIdx = runs[idx].toolEvents.firstIndex(where: { $0.id == tool.id }) {
                    runs[idx].toolEvents[tIdx] = tool
                } else {
                    runs[idx].toolEvents.append(tool)
                }
            }
        case .runCompleted(let runID, _, _, _):
            if let idx = runs.firstIndex(where: { $0.id == runID }) {
                runs[idx].status = .completed
                runs[idx].finishedAt = Date()
            }
        case .runFailed(let runID, _, _, let err):
            if let idx = runs.firstIndex(where: { $0.id == runID }) {
                runs[idx].status = .failed
                runs[idx].error = err
                runs[idx].finishedAt = Date()
            }
        case .runCancelled(let runID, _, _):
            if let idx = runs.firstIndex(where: { $0.id == runID }) {
                runs[idx].status = .cancelled
                runs[idx].finishedAt = Date()
            }
        default:
            break
        }
    }
}
