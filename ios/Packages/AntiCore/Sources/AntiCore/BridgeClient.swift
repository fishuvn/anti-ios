import Foundation

/// Lightweight closure-based API + WebSocket client (`swiftui-ui-patterns` pattern).
/// Easily swappable between live remote bridge hosts and offline Demo/test implementations.
public struct BridgeClient: Sendable {
    public var health: @Sendable () async throws -> HealthResponse
    public var claimPairing: @Sendable (_ code: String) async throws -> PairingClaimResponse
    public var createPairingCode: @Sendable () async throws -> PairingCreateResponse
    public var status: @Sendable () async throws -> HostStatus
    public var daemonControl: @Sendable (_ action: DaemonAction) async throws -> DaemonStatus
    public var commands: @Sendable () async throws -> [SlashCommandItem]
    public var sessions: @Sendable () async throws -> [SessionSummary]
    public var createSession: @Sendable (_ title: String?, _ workspaceID: String?) async throws -> SessionDetail
    public var sessionDetail: @Sendable (_ id: String) async throws -> SessionDetail
    public var deleteSession: @Sendable (_ id: String) async throws -> Void
    public var sendMessage: @Sendable (_ sessionID: String, _ prompt: String, _ slashCommand: String?, _ workspaceID: String?) async throws -> DispatchMessageResponse
    public var runs: @Sendable () async throws -> [AgentRun]
    public var cancelRun: @Sendable (_ runID: String) async throws -> AgentRun
    public var workspaces: @Sendable () async throws -> [WorkspaceInfo]
    public var listFiles: @Sendable (_ workspaceID: String, _ relativePath: String) async throws -> DirectoryListing
    public var readFile: @Sendable (_ workspaceID: String, _ relativePath: String) async throws -> FilePreview
    public var gitDetail: @Sendable (_ workspaceID: String) async throws -> GitDetail
    public var settings: @Sendable () async throws -> RemoteSettings
    public var updateSettings: @Sendable (_ patch: RemoteSettingsPatch) async throws -> RemoteSettings
    public var streamEvents: @Sendable () -> AsyncThrowingStream<BridgeStreamEvent, any Error>

    public init(
        health: @escaping @Sendable () async throws -> HealthResponse,
        claimPairing: @escaping @Sendable (_ code: String) async throws -> PairingClaimResponse,
        createPairingCode: @escaping @Sendable () async throws -> PairingCreateResponse,
        status: @escaping @Sendable () async throws -> HostStatus,
        daemonControl: @escaping @Sendable (_ action: DaemonAction) async throws -> DaemonStatus,
        commands: @escaping @Sendable () async throws -> [SlashCommandItem],
        sessions: @escaping @Sendable () async throws -> [SessionSummary],
        createSession: @escaping @Sendable (_ title: String?, _ workspaceID: String?) async throws -> SessionDetail,
        sessionDetail: @escaping @Sendable (_ id: String) async throws -> SessionDetail,
        deleteSession: @escaping @Sendable (_ id: String) async throws -> Void,
        sendMessage: @escaping @Sendable (_ sessionID: String, _ prompt: String, _ slashCommand: String?, _ workspaceID: String?) async throws -> DispatchMessageResponse,
        runs: @escaping @Sendable () async throws -> [AgentRun],
        cancelRun: @escaping @Sendable (_ runID: String) async throws -> AgentRun,
        workspaces: @escaping @Sendable () async throws -> [WorkspaceInfo],
        listFiles: @escaping @Sendable (_ workspaceID: String, _ relativePath: String) async throws -> DirectoryListing,
        readFile: @escaping @Sendable (_ workspaceID: String, _ relativePath: String) async throws -> FilePreview,
        gitDetail: @escaping @Sendable (_ workspaceID: String) async throws -> GitDetail,
        settings: @escaping @Sendable () async throws -> RemoteSettings,
        updateSettings: @escaping @Sendable (_ patch: RemoteSettingsPatch) async throws -> RemoteSettings,
        streamEvents: @escaping @Sendable () -> AsyncThrowingStream<BridgeStreamEvent, any Error>
    ) {
        self.health = health
        self.claimPairing = claimPairing
        self.createPairingCode = createPairingCode
        self.status = status
        self.daemonControl = daemonControl
        self.commands = commands
        self.sessions = sessions
        self.createSession = createSession
        self.sessionDetail = sessionDetail
        self.deleteSession = deleteSession
        self.sendMessage = sendMessage
        self.runs = runs
        self.cancelRun = cancelRun
        self.workspaces = workspaces
        self.listFiles = listFiles
        self.readFile = readFile
        self.gitDetail = gitDetail
        self.settings = settings
        self.updateSettings = updateSettings
        self.streamEvents = streamEvents
    }
}

// MARK: - Live HTTP(S) + WebSocket Client

private struct ErrorEnvelope: Decodable {
    let error: String?
}

private struct CommandsEnvelope: Decodable { let commands: [SlashCommandItem] }
private struct SessionsEnvelope: Decodable { let sessions: [SessionSummary] }
private struct RunsEnvelope: Decodable { let runs: [AgentRun] }
private struct CancelRunEnvelope: Decodable { let cancelled: Bool; let run: AgentRun }
private struct WorkspacesEnvelope: Decodable { let workspaces: [WorkspaceInfo] }

extension BridgeClient {
    public static func live(baseURL: URL, token: String?, session: URLSession? = nil) -> BridgeClient {
        let httpSession: URLSession = session ?? {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 60
            cfg.waitsForConnectivity = false
            return URLSession(configuration: cfg)
        }()

        let normalizedBase = baseURL

        @Sendable
        func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
            var comps = URLComponents(url: normalizedBase, resolvingAgainstBaseURL: false)
            let basePath = comps?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            comps?.path = basePath.isEmpty ? "/\(suffix)" : "/\(basePath)/\(suffix)"
            if !query.isEmpty {
                comps?.queryItems = query
            }
            guard let url = comps?.url else {
                throw BridgeError.invalidURL("\(normalizedBase.absoluteString)\(path)")
            }
            return url
        }

        @Sendable
        func perform<T: Decodable>(
            _ method: String,
            path: String,
            query: [URLQueryItem] = [],
            body: (any Encodable)? = nil,
            authenticated: Bool = true
        ) async throws -> T {
            let url = try makeURL(path, query: query)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if authenticated {
                guard let token, !token.isEmpty else {
                    throw BridgeError.unauthorized
                }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try BridgeJSON.encoder.encode(AnyEncodable(body))
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await httpSession.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw BridgeError.networkFailure(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw BridgeError.networkFailure("Invalid HTTP response")
            }

            if http.statusCode == 401 {
                throw BridgeError.unauthorized
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                let message = (try? BridgeJSON.decoder.decode(ErrorEnvelope.self, from: data).error)
                    ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                throw BridgeError.serverError(statusCode: http.statusCode, message: message)
            }

            do {
                return try BridgeJSON.decoder.decode(T.self, from: data)
            } catch {
                throw BridgeError.decodingFailure(error.localizedDescription)
            }
        }

        @Sendable
        func performVoid(_ method: String, path: String) async throws {
            struct EmptyAck: Decodable {}
            let _: EmptyAck = try await perform(method, path: path)
        }

        return BridgeClient(
            health: {
                try await perform("GET", path: "/v1/health", authenticated: false)
            },
            claimPairing: { code in
                struct Body: Encodable { let code: String }
                return try await perform(
                    "POST",
                    path: "/v1/pair/claim",
                    body: Body(code: code),
                    authenticated: false
                )
            },
            createPairingCode: {
                try await perform("POST", path: "/v1/pair/create")
            },
            status: {
                try await perform("GET", path: "/v1/status")
            },
            daemonControl: { action in
                try await perform("POST", path: "/v1/daemon/\(action.rawValue)")
            },
            commands: {
                let env: CommandsEnvelope = try await perform("GET", path: "/v1/commands")
                return env.commands
            },
            sessions: {
                let env: SessionsEnvelope = try await perform("GET", path: "/v1/sessions")
                return env.sessions
            },
            createSession: { title, workspaceID in
                struct Body: Encodable { let title: String?; let workspaceId: String? }
                return try await perform(
                    "POST",
                    path: "/v1/sessions",
                    body: Body(title: title, workspaceId: workspaceID)
                )
            },
            sessionDetail: { id in
                try await perform("GET", path: "/v1/sessions/\(id)")
            },
            deleteSession: { id in
                try await performVoid("DELETE", path: "/v1/sessions/\(id)")
            },
            sendMessage: { sessionID, prompt, slashCommand, workspaceID in
                struct Body: Encodable {
                    let prompt: String
                    let slashCommand: String?
                    let workspaceId: String?
                }
                return try await perform(
                    "POST",
                    path: "/v1/sessions/\(sessionID)/messages",
                    body: Body(prompt: prompt, slashCommand: slashCommand, workspaceId: workspaceID)
                )
            },
            runs: {
                let env: RunsEnvelope = try await perform("GET", path: "/v1/runs")
                return env.runs
            },
            cancelRun: { runID in
                let env: CancelRunEnvelope = try await perform("POST", path: "/v1/runs/\(runID)/cancel")
                return env.run
            },
            workspaces: {
                let env: WorkspacesEnvelope = try await perform("GET", path: "/v1/workspaces")
                return env.workspaces
            },
            listFiles: { workspaceID, relativePath in
                let query = relativePath.isEmpty ? [] : [URLQueryItem(name: "path", value: relativePath)]
                return try await perform("GET", path: "/v1/workspaces/\(workspaceID)/files", query: query)
            },
            readFile: { workspaceID, relativePath in
                try await perform(
                    "GET",
                    path: "/v1/workspaces/\(workspaceID)/file",
                    query: [URLQueryItem(name: "path", value: relativePath)]
                )
            },
            gitDetail: { workspaceID in
                try await perform("GET", path: "/v1/workspaces/\(workspaceID)/git")
            },
            settings: {
                try await perform("GET", path: "/v1/settings")
            },
            updateSettings: { patch in
                try await perform("PATCH", path: "/v1/settings", body: patch)
            },
            streamEvents: {
                AsyncThrowingStream { continuation in
                    let streamTask = Task {
                        do {
                            guard let token, !token.isEmpty else {
                                throw BridgeError.unauthorized
                            }
                            var comps = URLComponents(url: normalizedBase, resolvingAgainstBaseURL: false)
                            comps?.scheme = normalizedBase.scheme?.lowercased() == "https" ? "wss" : "ws"
                            let basePath = comps?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
                            comps?.path = basePath.isEmpty ? "/v1/stream" : "/\(basePath)/v1/stream"
                            guard let wsURL = comps?.url else {
                                throw BridgeError.invalidURL(normalizedBase.absoluteString)
                            }

                            var req = URLRequest(url: wsURL)
                            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                            let wsTask = httpSession.webSocketTask(with: req)
                            wsTask.resume()
                            defer {
                                wsTask.cancel(with: .goingAway, reason: nil)
                            }

                            while !Task.isCancelled {
                                let message = try await wsTask.receive()
                                let data: Data
                                switch message {
                                case .string(let text):
                                    data = Data(text.utf8)
                                case .data(let raw):
                                    data = raw
                                @unknown default:
                                    continue
                                }
                                if let event = try? BridgeStreamEvent.decode(from: data) {
                                    continuation.yield(event)
                                }
                            }
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }

                    continuation.onTermination = { _ in
                        streamTask.cancel()
                    }
                }
            }
        )
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (any Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        self.encodeImpl = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: any Encoder) throws {
        try encodeImpl(encoder)
    }
}

// MARK: - Rich Offline Demo Client (Instant Simulator & Preview Exploration)

private actor DemoBackendState {
    var daemon = DaemonStatus(
        state: .running,
        url: "https://antigravity.local/remote-control/demo",
        detail: "Simulated remote-control daemon active. Pair your remote Linux/Mac bridge in Settings.",
        updatedAt: Date()
    )
    var settings = RemoteSettings(
        modelProvider: "gemini",
        permissionMode: "ask",
        trustedWorkspaces: ["/srv/antigravity/anti-ios", "/srv/antigravity/api-gateway"],
        mcpServers: [
            MCPServerSummary(name: "graphify", transport: "stdio", target: "graphify-mcp", enabled: true),
            MCPServerSummary(name: "postgres-prod-ro", transport: "http-sse", target: "https://mcp.internal/pg", enabled: true),
        ],
        configPath: "~/.gemini/antigravity-cli/settings.json"
    )
    var sessions: [String: SessionDetail]
    var runs: [AgentRun] = []
    private var continuations: [UUID: AsyncThrowingStream<BridgeStreamEvent, any Error>.Continuation] = [:]

    let workspaces: [WorkspaceInfo] = [
        WorkspaceInfo(
            id: "ws-anti-ios",
            name: "anti-ios",
            path: "/srv/antigravity/anti-ios",
            isGitRepo: true,
            branch: "main",
            dirtyCount: 2
        ),
        WorkspaceInfo(
            id: "ws-gateway",
            name: "api-gateway",
            path: "/srv/antigravity/api-gateway",
            isGitRepo: true,
            branch: "feat/ws-stream",
            dirtyCount: 0
        ),
    ]

    let commands: [SlashCommandItem] = [
        SlashCommandItem(id: "plan", command: "/plan", title: "Plan Task", description: "Draft a step-by-step execution plan", symbol: "list.bullet.clipboard", category: "workflow", template: "/plan ", autoSend: false),
        SlashCommandItem(id: "goal", command: "/goal", title: "Autonomous Goal", description: "Run thorough multi-step execution until verified", symbol: "target", category: "workflow", template: "/goal ", autoSend: false),
        SlashCommandItem(id: "agents", command: "/agents", title: "Agents Panel", description: "Inspect active subagents and background workers", symbol: "person.3.sequence", category: "control", template: "/agents", autoSend: true),
        SlashCommandItem(id: "compact", command: "/compact", title: "Compact Context", description: "Summarize session history to free context", symbol: "arrow.down.right.and.arrow.up.left", category: "session", template: "/compact", autoSend: true),
        SlashCommandItem(id: "remote-control", command: "/remote-control", title: "Remote Link", description: "Check Antigravity remote control status", symbol: "antenna.radiowaves.left.and.right", category: "control", template: "/remote-control", autoSend: true),
        SlashCommandItem(id: "status", command: "/status", title: "Host Status", description: "Workspace, branch, and daemon health", symbol: "waveform.path.ecg", category: "control", template: "/status", autoSend: true),
        SlashCommandItem(id: "diff", command: "/diff", title: "Summarize Diff", description: "Review uncommitted changes in active repo", symbol: "doc.text.magnifyingglass", category: "workspace", template: "Summarize uncommitted git diff and flag risks.", autoSend: true),
        SlashCommandItem(id: "test", command: "/test", title: "Run Tests", description: "Execute test suite and report failures", symbol: "checkmark.shield", category: "workspace", template: "Run the test suite and summarize failures.", autoSend: true),
    ]

    init() {
        let now = Date()
        let mainID = "demo-session-main"
        let welcomeMsg = ChatMessage(
            id: "demo-msg-1",
            role: .assistant,
            content: "Demo Rig connected. Tap any slash command chip below to test live streaming, or pair your remote Antigravity bridge in Settings -> Pair via QR.",
            slashCommand: nil,
            status: .completed,
            toolEvents: [
                ToolActivityEvent(
                    id: "demo-tool-0",
                    name: "bridge.handshake",
                    status: "completed",
                    summary: "Connected to Demo Rig (/srv/antigravity/anti-ios)",
                    timestamp: now.addingTimeInterval(-30)
                ),
            ],
            createdAt: now.addingTimeInterval(-30)
        )
        self.sessions = [
            mainID: SessionDetail(
                id: mainID,
                title: "Main Control Session",
                workspaceId: "ws-anti-ios",
                createdAt: now.addingTimeInterval(-120),
                updatedAt: now.addingTimeInterval(-30),
                messages: [welcomeMsg]
            ),
        ]
    }

    func registerStream(_ id: UUID, continuation: AsyncThrowingStream<BridgeStreamEvent, any Error>.Continuation) {
        continuations[id] = continuation
        continuation.yield(.connected(serverTime: Date(), daemon: daemon))
    }

    func unregisterStream(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func broadcast(_ event: BridgeStreamEvent) {
        for c in continuations.values {
            c.yield(event)
        }
    }

    func toggleDaemon(_ action: DaemonAction) -> DaemonStatus {
        let now = Date()
        switch action {
        case .start:
            daemon = DaemonStatus(state: .running, url: "https://antigravity.local/remote-control/demo", detail: "Demo remote-control daemon running", updatedAt: now)
        case .stop:
            daemon = DaemonStatus(state: .stopped, url: nil, detail: "Demo remote-control daemon stopped", updatedAt: now)
        case .status:
            break
        }
        broadcast(.daemonUpdated(daemon: daemon))
        return daemon
    }

    func listSummaries() -> [SessionSummary] {
        sessions.values
            .map { s in
                let active = runs.first { $0.sessionId == s.id && $0.status == .streaming }
                return SessionSummary(
                    id: s.id,
                    title: s.title,
                    workspaceId: s.workspaceId,
                    updatedAt: s.updatedAt,
                    messageCount: s.messages.count,
                    activeRunId: active?.id,
                    lastPreview: String((s.messages.last?.content ?? "No messages yet").prefix(120))
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func createSession(title: String?, workspaceID: String?) -> SessionDetail {
        let now = Date()
        let detail = SessionDetail(
            id: UUID().uuidString,
            title: (title?.isEmpty == false) ? title! : "New Session",
            workspaceId: workspaceID ?? workspaces[0].id,
            createdAt: now,
            updatedAt: now,
            messages: []
        )
        sessions[detail.id] = detail
        return detail
    }

    func getSession(_ id: String) throws -> SessionDetail {
        guard let session = sessions[id] else {
            throw BridgeError.serverError(statusCode: 404, message: "Session not found")
        }
        return session
    }

    func deleteSession(_ id: String) {
        sessions.removeValue(forKey: id)
    }

    func dispatch(sessionID: String, prompt: String, slashCommand: String?, workspaceID: String?) throws -> DispatchMessageResponse {
        guard var session = sessions[sessionID] else {
            throw BridgeError.serverError(statusCode: 404, message: "Session not found")
        }
        let now = Date()
        let userMsg = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            content: prompt,
            slashCommand: slashCommand,
            status: .completed,
            createdAt: now
        )
        let assistantID = UUID().uuidString
        let assistantMsg = ChatMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            slashCommand: slashCommand,
            status: .streaming,
            createdAt: now
        )
        session.messages.append(userMsg)
        session.messages.append(assistantMsg)
        if session.title == "New Session" {
            session.title = String(prompt.prefix(40))
        }
        session.updatedAt = now
        sessions[sessionID] = session

        let runID = UUID().uuidString
        let run = AgentRun(
            id: runID,
            sessionId: sessionID,
            workspaceId: workspaceID ?? session.workspaceId,
            assistantMessageId: assistantID,
            prompt: prompt,
            status: .streaming,
            startedAt: now
        )
        runs.insert(run, at: 0)
        broadcast(.runStarted(runId: runID, sessionId: sessionID, messageId: assistantID, prompt: prompt))

        Task {
            await self.simulateStreaming(runID: runID, sessionID: sessionID, messageID: assistantID, prompt: prompt, slashCommand: slashCommand)
        }

        return DispatchMessageResponse(runId: runID, sessionId: sessionID, userMessage: userMsg, assistantMessage: assistantMsg)
    }

    private func simulateStreaming(runID: String, sessionID: String, messageID: String, prompt: String, slashCommand: String?) async {
        let toolID = UUID().uuidString
        let toolName = slashCommand.map { "slash:\($0)" } ?? "agy.execute"
        let startTool = ToolActivityEvent(
            id: toolID,
            name: toolName,
            status: "running",
            summary: "Inspecting workspace /srv/antigravity/anti-ios",
            timestamp: Date()
        )
        recordTool(runID: runID, sessionID: sessionID, messageID: messageID, event: startTool)

        let chunks: [String] = switch slashCommand {
        case "/agents":
            ["Remote subagents active:\n\n", "• **coordinator** — ready\n", "• **code-reviewer** — standby\n", "• **test-engineer** — standby"]
        case "/plan":
            ["Execution plan ready:\n\n", "1. Verify workspace branch & clean diff.\n", "2. Implement scoped change.\n", "3. Run automated tests and report status."]
        case "/compact":
            ["Session context compacted. ", "Preserved open tasks, workspace root, and active diff state."]
        default:
            ["[Demo Rig] Executed: \"\(prompt)\"\n\n", "Streaming WebSocket chunks verified in real time. ", "Connect your remote bridge in Settings to drive live `agy` CLI sessions."]
        }

        var full = ""
        for chunk in chunks {
            try? await Task.sleep(for: .milliseconds(70))
            if isCancelled(runID: runID) { return }
            full += chunk
            appendDelta(sessionID: sessionID, messageID: messageID, delta: chunk)
            broadcast(.messageDelta(runId: runID, sessionId: sessionID, messageId: messageID, delta: chunk))
        }

        if isCancelled(runID: runID) { return }
        let doneTool = ToolActivityEvent(
            id: toolID,
            name: toolName,
            status: "completed",
            summary: "Completed cleanly",
            timestamp: Date()
        )
        recordTool(runID: runID, sessionID: sessionID, messageID: messageID, event: doneTool)

        if let idx = runs.firstIndex(where: { $0.id == runID }) {
            runs[idx].status = .completed
            runs[idx].finishedAt = Date()
        }
        var finalMsg: ChatMessage?
        if var session = sessions[sessionID],
           let mIdx = session.messages.firstIndex(where: { $0.id == messageID }) {
            session.messages[mIdx].content = full
            session.messages[mIdx].status = .completed
            session.updatedAt = Date()
            finalMsg = session.messages[mIdx]
            sessions[sessionID] = session
        }
        broadcast(.runCompleted(runId: runID, sessionId: sessionID, messageId: messageID, message: finalMsg))
    }

    private func isCancelled(runID: String) -> Bool {
        runs.first(where: { $0.id == runID })?.status == .cancelled
    }

    private func appendDelta(sessionID: String, messageID: String, delta: String) {
        guard var session = sessions[sessionID],
              let idx = session.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        session.messages[idx].content += delta
        sessions[sessionID] = session
    }

    private func recordTool(runID: String, sessionID: String, messageID: String, event: ToolActivityEvent) {
        if let rIdx = runs.firstIndex(where: { $0.id == runID }) {
            if let tIdx = runs[rIdx].toolEvents.firstIndex(where: { $0.id == event.id }) {
                runs[rIdx].toolEvents[tIdx] = event
            } else {
                runs[rIdx].toolEvents.append(event)
            }
        }
        if var session = sessions[sessionID],
           let mIdx = session.messages.firstIndex(where: { $0.id == messageID }) {
            if let tIdx = session.messages[mIdx].toolEvents.firstIndex(where: { $0.id == event.id }) {
                session.messages[mIdx].toolEvents[tIdx] = event
            } else {
                session.messages[mIdx].toolEvents.append(event)
            }
            sessions[sessionID] = session
        }
        broadcast(.toolEvent(runId: runID, sessionId: sessionID, messageId: messageID, event: event))
    }

    func cancelRun(_ runID: String) throws -> AgentRun {
        guard let idx = runs.firstIndex(where: { $0.id == runID }) else {
            throw BridgeError.serverError(statusCode: 404, message: "Active run not found")
        }
        runs[idx].status = .cancelled
        runs[idx].finishedAt = Date()
        let run = runs[idx]
        if var session = sessions[run.sessionId],
           let mIdx = session.messages.firstIndex(where: { $0.id == run.assistantMessageId }) {
            session.messages[mIdx].status = .cancelled
            sessions[run.sessionId] = session
        }
        broadcast(.runCancelled(runId: run.id, sessionId: run.sessionId, messageId: run.assistantMessageId))
        return run
    }

    func updateSettings(_ patch: RemoteSettingsPatch) -> RemoteSettings {
        settings = RemoteSettings(
            modelProvider: patch.modelProvider ?? settings.modelProvider,
            permissionMode: patch.permissionMode ?? settings.permissionMode,
            trustedWorkspaces: settings.trustedWorkspaces,
            mcpServers: settings.mcpServers,
            configPath: settings.configPath
        )
        return settings
    }
}

extension BridgeClient {
    public static func demo() -> BridgeClient {
        let state = DemoBackendState()
        return BridgeClient(
            health: {
                HealthResponse(ok: true, service: "antiremote-demo", version: "1.0.0", requiresAuth: false, timestamp: Date())
            },
            claimPairing: { _ in
                PairingClaimResponse(token: "demo-token", hostName: "Demo Rig", serverVersion: "1.0.0", adapter: "demo")
            },
            createPairingCode: {
                PairingCreateResponse(
                    code: "DEMO-2026",
                    expiresAt: Date().addingTimeInterval(600),
                    pairingURI: "antiremote://pair?url=https://demo.antiremote.local&code=DEMO-2026&name=Demo+Rig"
                )
            },
            status: {
                let daemon = await state.daemon
                let settings = await state.settings
                let activeCount = await state.runs.filter { $0.status == .streaming }.count
                return HostStatus(
                    hostname: "demo-rig.local",
                    platform: "linux-arm64",
                    uptimeSeconds: 14_820,
                    serverVersion: "1.0.0",
                    adapter: "demo",
                    agyInstalled: true,
                    agyVersion: "2.0.0-demo",
                    daemon: daemon,
                    activeRunsCount: activeCount,
                    workspacesCount: state.workspaces.count,
                    modelProvider: settings.modelProvider,
                    permissionMode: settings.permissionMode
                )
            },
            daemonControl: { action in
                await state.toggleDaemon(action)
            },
            commands: {
                state.commands
            },
            sessions: {
                await state.listSummaries()
            },
            createSession: { title, workspaceID in
                await state.createSession(title: title, workspaceID: workspaceID)
            },
            sessionDetail: { id in
                try await state.getSession(id)
            },
            deleteSession: { id in
                await state.deleteSession(id)
            },
            sendMessage: { sessionID, prompt, slashCommand, workspaceID in
                try await state.dispatch(sessionID: sessionID, prompt: prompt, slashCommand: slashCommand, workspaceID: workspaceID)
            },
            runs: {
                await state.runs
            },
            cancelRun: { runID in
                try await state.cancelRun(runID)
            },
            workspaces: {
                state.workspaces
            },
            listFiles: { _, relPath in
                let now = Date()
                if relPath.isEmpty {
                    return DirectoryListing(path: "", entries: [
                        FileEntry(name: "bridge", path: "bridge", isDirectory: true, size: 0, modifiedAt: now),
                        FileEntry(name: "ios", path: "ios", isDirectory: true, size: 0, modifiedAt: now),
                        FileEntry(name: "DESIGN.md", path: "DESIGN.md", isDirectory: false, size: 4280, modifiedAt: now),
                        FileEntry(name: "PRODUCT.md", path: "PRODUCT.md", isDirectory: false, size: 3120, modifiedAt: now),
                    ])
                }
                return DirectoryListing(path: relPath, entries: [
                    FileEntry(name: "server.mjs", path: "\(relPath)/server.mjs", isDirectory: false, size: 9120, modifiedAt: now),
                    FileEntry(name: "cli.mjs", path: "\(relPath)/cli.mjs", isDirectory: false, size: 2840, modifiedAt: now),
                ])
            },
            readFile: { _, relPath in
                FilePreview(
                    path: relPath,
                    size: 210,
                    truncated: false,
                    isBinary: false,
                    content: """
                    // Preview of \(relPath) on Demo Rig
                    // Connect your remote bridge to inspect live files and git diffs.
                    export const status = "ready";
                    """
                )
            },
            gitDetail: { _ in
                GitDetail(
                    isGitRepo: true,
                    branch: "main",
                    changedFiles: [
                        GitChangedFile(status: "M", path: "bridge/src/server.mjs"),
                        GitChangedFile(status: "A", path: "ios/project.yml"),
                    ],
                    diff: """
                    diff --git a/bridge/src/server.mjs b/bridge/src/server.mjs
                    --- a/bridge/src/server.mjs
                    +++ b/bridge/src/server.mjs
                    @@ -12,4 +12,6 @@
                    +export async function createBridgeServer(options = {}) {
                    +  // Authenticated REST + WebSocket streaming active
                    """
                )
            },
            settings: {
                await state.settings
            },
            updateSettings: { patch in
                await state.updateSettings(patch)
            },
            streamEvents: {
                AsyncThrowingStream { continuation in
                    let id = UUID()
                    Task {
                        await state.registerStream(id, continuation: continuation)
                    }
                    continuation.onTermination = { _ in
                        Task { await state.unregisterStream(id) }
                    }
                }
            }
        )
    }
}
