import AntiCore
import Foundation
import os

@MainActor
@Observable
final class ChatStore {
    private static let logger = Logger(subsystem: "com.antiremote.app", category: "chat")

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var state: LoadState = .idle
    var sessions: [SessionSummary] = []
    var activeSession: SessionDetail?
    var slashCommands: [SlashCommandItem] = []
    var composerText: String = ""
    var activeRunID: String?
    var isSending = false
    var errorMessage: String?

    func reset() {
        state = .idle
        sessions = []
        activeSession = nil
        slashCommands = []
        activeRunID = nil
        isSending = false
        errorMessage = nil
    }

    func loadInitial(using client: BridgeClient) async {
        state = .loading
        errorMessage = nil
        do {
            async let sessionsTask = client.sessions()
            async let commandsTask = client.commands()
            let (loadedSessions, loadedCommands) = try await (sessionsTask, commandsTask)
            guard !Task.isCancelled else { return }

            sessions = loadedSessions
            slashCommands = loadedCommands

            if let first = loadedSessions.first {
                activeSession = try await client.sessionDetail(first.id)
                activeRunID = first.activeRunId
            } else {
                let created = try await client.createSession("Main Control Session", nil)
                activeSession = created
                sessions = try await client.sessions()
            }
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Chat load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func selectSession(_ id: String, using client: BridgeClient) async {
        errorMessage = nil
        do {
            let detail = try await client.sessionDetail(id)
            activeSession = detail
            activeRunID = sessions.first(where: { $0.id == id })?.activeRunId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSession(title: String? = nil, workspaceID: String? = nil, using client: BridgeClient) async {
        errorMessage = nil
        do {
            let created = try await client.createSession(title, workspaceID)
            activeSession = created
            activeRunID = nil
            sessions = try await client.sessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ id: String, using client: BridgeClient) async {
        errorMessage = nil
        do {
            try await client.deleteSession(id)
            sessions = try await client.sessions()
            if activeSession?.id == id {
                if let next = sessions.first {
                    activeSession = try await client.sessionDetail(next.id)
                } else {
                    await createSession(title: "Main Control Session", using: client)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendCurrentComposer(
        workspaceID: String? = nil,
        using client: BridgeClient,
        hapticsEnabled: Bool
    ) async {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let slash: String? = prompt.hasPrefix("/") ? String(prompt.split(separator: " ").first ?? "") : nil
        composerText = ""
        await sendPrompt(prompt, slashCommand: slash, workspaceID: workspaceID, using: client, hapticsEnabled: hapticsEnabled)
    }

    func triggerSlashCommand(
        _ item: SlashCommandItem,
        workspaceID: String? = nil,
        using client: BridgeClient,
        hapticsEnabled: Bool
    ) async {
        if item.autoSend {
            await sendPrompt(
                item.template,
                slashCommand: item.command,
                workspaceID: workspaceID,
                using: client,
                hapticsEnabled: hapticsEnabled
            )
        } else {
            composerText = item.template
            HapticManager.shared.fire(.selection, enabled: hapticsEnabled)
        }
    }

    func sendPrompt(
        _ prompt: String,
        slashCommand: String? = nil,
        workspaceID: String? = nil,
        using client: BridgeClient,
        hapticsEnabled: Bool
    ) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let sessionID: String
            if let existing = activeSession {
                sessionID = existing.id
            } else {
                let created = try await client.createSession(nil, workspaceID)
                activeSession = created
                sessionID = created.id
            }

            HapticManager.shared.fire(.lightImpact, enabled: hapticsEnabled)
            let response = try await client.sendMessage(sessionID, trimmed, slashCommand, workspaceID)
            activeRunID = response.runId

            if var current = activeSession, current.id == response.sessionId {
                if !current.messages.contains(where: { $0.id == response.userMessage.id }) {
                    current.messages.append(response.userMessage)
                }
                if !current.messages.contains(where: { $0.id == response.assistantMessage.id }) {
                    current.messages.append(response.assistantMessage)
                }
                current.updatedAt = Date()
                activeSession = current
            }
            sessions = (try? await client.sessions()) ?? sessions
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.shared.fire(.error, enabled: hapticsEnabled)
        }
    }

    func cancelActiveRun(using client: BridgeClient, hapticsEnabled: Bool) async {
        guard let runID = activeRunID else { return }
        do {
            _ = try await client.cancelRun(runID)
            activeRunID = nil
            HapticManager.shared.fire(.warning, enabled: hapticsEnabled)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleStreamEvent(_ event: BridgeStreamEvent) {
        switch event {
        case .runStarted(let runID, let sessionID, _, _):
            if activeSession?.id == sessionID {
                activeRunID = runID
            }

        case .messageDelta(_, let sessionID, let messageID, let delta):
            guard var session = activeSession, session.id == sessionID else { return }
            if let idx = session.messages.firstIndex(where: { $0.id == messageID }) {
                session.messages[idx].content += delta
                session.messages[idx].status = .streaming
            } else {
                session.messages.append(
                    ChatMessage(id: messageID, role: .assistant, content: delta, status: .streaming)
                )
            }
            activeSession = session

        case .toolEvent(_, let sessionID, let messageID, let tool):
            guard var session = activeSession, session.id == sessionID,
                  let idx = session.messages.firstIndex(where: { $0.id == messageID })
            else { return }
            if let tIdx = session.messages[idx].toolEvents.firstIndex(where: { $0.id == tool.id }) {
                session.messages[idx].toolEvents[tIdx] = tool
            } else {
                session.messages[idx].toolEvents.append(tool)
            }
            activeSession = session

        case .runCompleted(let runID, let sessionID, let messageID, let message):
            if activeRunID == runID {
                activeRunID = nil
            }
            guard var session = activeSession, session.id == sessionID else { return }
            if let idx = session.messages.firstIndex(where: { $0.id == messageID }) {
                if let message {
                    session.messages[idx] = message
                } else {
                    session.messages[idx].status = .completed
                }
            }
            session.updatedAt = Date()
            activeSession = session

        case .runFailed(let runID, let sessionID, let messageID, let error):
            if activeRunID == runID {
                activeRunID = nil
            }
            errorMessage = error
            guard var session = activeSession, session.id == sessionID,
                  let idx = session.messages.firstIndex(where: { $0.id == messageID })
            else { return }
            session.messages[idx].status = .failed
            if session.messages[idx].content.isEmpty {
                session.messages[idx].content = "Error: \(error)"
            }
            activeSession = session

        case .runCancelled(let runID, let sessionID, let messageID):
            if activeRunID == runID {
                activeRunID = nil
            }
            guard var session = activeSession, session.id == sessionID,
                  let idx = session.messages.firstIndex(where: { $0.id == messageID })
            else { return }
            session.messages[idx].status = .cancelled
            activeSession = session

        case .connected, .daemonUpdated, .pong, .unknown:
            break
        }
    }
}
