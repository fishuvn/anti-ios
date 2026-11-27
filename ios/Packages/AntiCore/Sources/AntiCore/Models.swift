import Foundation

// MARK: - Host & Pairing Models

public struct HostProfile: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var baseURLString: String
    public var tlsFingerprint: String?
    public var isDemo: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        baseURLString: String,
        tlsFingerprint: String? = nil,
        isDemo: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.tlsFingerprint = tlsFingerprint
        self.isDemo = isDemo
        self.createdAt = createdAt
    }

    public var baseURL: URL? {
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var hostLabel: String {
        if isDemo { return "Simulated Local Host" }
        guard let url = baseURL, let host = url.host else { return baseURLString }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    public static let demoID = UUID(uuidString: "00000000-0000-0000-0000-00000000A117")!

    public static let demo = HostProfile(
        id: demoID,
        name: "Demo Rig (Offline Preview)",
        baseURLString: "https://demo.antiremote.local",
        isDemo: true,
        createdAt: Date(timeIntervalSince1970: 1_760_000_000)
    )
}

public struct PairingPayload: Sendable, Equatable, Hashable {
    public let baseURL: URL
    public let code: String
    public let hostName: String
    public let tlsFingerprint: String?

    public init(baseURL: URL, code: String, hostName: String, tlsFingerprint: String? = nil) {
        self.baseURL = baseURL
        self.code = code
        self.hostName = hostName
        self.tlsFingerprint = tlsFingerprint
    }

    /// Parses `antiremote://pair?url=http://192.168.1.5:8787&code=XXXX-XXXX&name=rig&fp=...`
    public static func parse(uri: String) throws -> PairingPayload {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "antiremote",
              (components.host?.lowercased() == "pair" || components.path.lowercased().hasSuffix("pair"))
        else {
            throw BridgeError.invalidPairingURI("Expected antiremote://pair?... link.")
        }

        let items = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        guard let rawURL = items["url"],
              let parsedURL = URL(string: rawURL),
              let scheme = parsedURL.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              parsedURL.host != nil
        else {
            throw BridgeError.invalidPairingURI("Pairing link is missing a valid http or https server URL.")
        }

        guard let code = items["code"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              code.count >= 4
        else {
            throw BridgeError.invalidPairingURI("Pairing link is missing a valid pairing code.")
        }

        let name = items["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name?.isEmpty == false) ? name! : (parsedURL.host ?? "Remote Host")
        let fp = items["fp"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingPayload(
            baseURL: parsedURL,
            code: code.uppercased(),
            hostName: resolvedName,
            tlsFingerprint: fp?.isEmpty == false ? fp : nil
        )
    }
}

public struct PairingClaimResponse: Sendable, Codable, Equatable {
    public let token: String
    public let hostName: String
    public let serverVersion: String
    public let adapter: String

    public init(token: String, hostName: String, serverVersion: String, adapter: String) {
        self.token = token
        self.hostName = hostName
        self.serverVersion = serverVersion
        self.adapter = adapter
    }
}

public struct PairingCreateResponse: Sendable, Codable, Equatable {
    public let code: String
    public let expiresAt: Date
    public let pairingURI: String

    public init(code: String, expiresAt: Date, pairingURI: String) {
        self.code = code
        self.expiresAt = expiresAt
        self.pairingURI = pairingURI
    }
}

// MARK: - Health, Status & Daemon

public struct HealthResponse: Sendable, Codable, Equatable {
    public let ok: Bool
    public let service: String
    public let version: String
    public let requiresAuth: Bool
    public let timestamp: Date

    public init(ok: Bool, service: String, version: String, requiresAuth: Bool, timestamp: Date) {
        self.ok = ok
        self.service = service
        self.version = version
        self.requiresAuth = requiresAuth
        self.timestamp = timestamp
    }
}

public enum DaemonLifecycleState: String, Sendable, Codable, Hashable {
    case running
    case stopped
    case error
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DaemonLifecycleState(rawValue: raw) ?? .unknown
    }
}

public struct DaemonStatus: Sendable, Codable, Equatable {
    public let state: DaemonLifecycleState
    public let url: String?
    public let detail: String
    public let updatedAt: Date

    public init(state: DaemonLifecycleState, url: String?, detail: String, updatedAt: Date) {
        self.state = state
        self.url = url
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

public enum DaemonAction: String, Sendable, CaseIterable {
    case start
    case stop
    case status
}

public struct HostStatus: Sendable, Codable, Equatable {
    public let hostname: String
    public let platform: String
    public let uptimeSeconds: Int
    public let serverVersion: String
    public let adapter: String
    public let agyInstalled: Bool
    public let agyVersion: String?
    public let daemon: DaemonStatus
    public let activeRunsCount: Int
    public let workspacesCount: Int
    public let modelProvider: String
    public let permissionMode: String

    public init(
        hostname: String,
        platform: String,
        uptimeSeconds: Int,
        serverVersion: String,
        adapter: String,
        agyInstalled: Bool,
        agyVersion: String?,
        daemon: DaemonStatus,
        activeRunsCount: Int,
        workspacesCount: Int,
        modelProvider: String,
        permissionMode: String
    ) {
        self.hostname = hostname
        self.platform = platform
        self.uptimeSeconds = uptimeSeconds
        self.serverVersion = serverVersion
        self.adapter = adapter
        self.agyInstalled = agyInstalled
        self.agyVersion = agyVersion
        self.daemon = daemon
        self.activeRunsCount = activeRunsCount
        self.workspacesCount = workspacesCount
        self.modelProvider = modelProvider
        self.permissionMode = permissionMode
    }
}

// MARK: - Sessions, Messages, Runs & Slash Commands

public struct ToolActivityEvent: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let status: String
    public let summary: String
    public let timestamp: Date

    public init(id: String, name: String, status: String, summary: String, timestamp: Date) {
        self.id = id
        self.name = name
        self.status = status
        self.summary = summary
        self.timestamp = timestamp
    }
}

public enum MessageRole: String, Sendable, Codable, Hashable {
    case user
    case assistant
    case system
}

public enum MessageStatus: String, Sendable, Codable, Hashable {
    case streaming
    case completed
    case failed
    case cancelled
}

public struct ChatMessage: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let role: MessageRole
    public var content: String
    public let slashCommand: String?
    public var status: MessageStatus
    public var toolEvents: [ToolActivityEvent]
    public let createdAt: Date

    public init(
        id: String,
        role: MessageRole,
        content: String,
        slashCommand: String? = nil,
        status: MessageStatus = .completed,
        toolEvents: [ToolActivityEvent] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.slashCommand = slashCommand
        self.status = status
        self.toolEvents = toolEvents
        self.createdAt = createdAt
    }
}

public struct SessionSummary: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let title: String
    public let workspaceId: String
    public let updatedAt: Date
    public let messageCount: Int
    public let activeRunId: String?
    public let lastPreview: String

    public init(
        id: String,
        title: String,
        workspaceId: String,
        updatedAt: Date,
        messageCount: Int,
        activeRunId: String?,
        lastPreview: String
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.activeRunId = activeRunId
        self.lastPreview = lastPreview
    }
}

public struct SessionDetail: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var workspaceId: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]

    public init(
        id: String,
        title: String,
        workspaceId: String,
        createdAt: Date,
        updatedAt: Date,
        messages: [ChatMessage]
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

public struct DispatchMessageResponse: Sendable, Codable, Equatable {
    public let runId: String
    public let sessionId: String
    public let userMessage: ChatMessage
    public let assistantMessage: ChatMessage

    public init(runId: String, sessionId: String, userMessage: ChatMessage, assistantMessage: ChatMessage) {
        self.runId = runId
        self.sessionId = sessionId
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
    }
}

public struct AgentRun: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public let workspaceId: String
    public let assistantMessageId: String
    public let prompt: String
    public var status: MessageStatus
    public let startedAt: Date
    public var finishedAt: Date?
    public var toolEvents: [ToolActivityEvent]
    public var error: String?

    public init(
        id: String,
        sessionId: String,
        workspaceId: String,
        assistantMessageId: String,
        prompt: String,
        status: MessageStatus,
        startedAt: Date,
        finishedAt: Date? = nil,
        toolEvents: [ToolActivityEvent] = [],
        error: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.assistantMessageId = assistantMessageId
        self.prompt = prompt
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.toolEvents = toolEvents
        self.error = error
    }

    public enum CodingKeys: String, CodingKey {
        case id, sessionId, workspaceId, assistantMessageId, prompt, status, startedAt, finishedAt, toolEvents, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        workspaceId = try container.decode(String.self, forKey: .workspaceId)
        assistantMessageId = try container.decode(String.self, forKey: .assistantMessageId)
        prompt = try container.decode(String.self, forKey: .prompt)
        let rawStatus = try container.decode(String.self, forKey: .status)
        status = rawStatus == "running" ? .streaming : (MessageStatus(rawValue: rawStatus) ?? .completed)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        toolEvents = try container.decodeIfPresent([ToolActivityEvent].self, forKey: .toolEvents) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct SlashCommandItem: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let command: String
    public let title: String
    public let description: String
    public let symbol: String
    public let category: String
    public let template: String
    public let autoSend: Bool

    public init(
        id: String,
        command: String,
        title: String,
        description: String,
        symbol: String,
        category: String,
        template: String,
        autoSend: Bool
    ) {
        self.id = id
        self.command = command
        self.title = title
        self.description = description
        self.symbol = symbol
        self.category = category
        self.template = template
        self.autoSend = autoSend
    }
}

// MARK: - Workspaces & Git

public struct WorkspaceInfo: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let isGitRepo: Bool
    public let branch: String?
    public let dirtyCount: Int

    public init(id: String, name: String, path: String, isGitRepo: Bool, branch: String?, dirtyCount: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.isGitRepo = isGitRepo
        self.branch = branch
        self.dirtyCount = dirtyCount
    }
}

public struct FileEntry: Sendable, Codable, Identifiable, Equatable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int
    public let modifiedAt: Date

    public init(name: String, path: String, isDirectory: Bool, size: Int, modifiedAt: Date) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct DirectoryListing: Sendable, Codable, Equatable {
    public let path: String
    public let entries: [FileEntry]

    public init(path: String, entries: [FileEntry]) {
        self.path = path
        self.entries = entries
    }
}

public struct FilePreview: Sendable, Codable, Equatable {
    public let path: String
    public let size: Int
    public let truncated: Bool
    public let isBinary: Bool
    public let content: String

    public init(path: String, size: Int, truncated: Bool, isBinary: Bool, content: String) {
        self.path = path
        self.size = size
        self.truncated = truncated
        self.isBinary = isBinary
        self.content = content
    }
}

public struct GitChangedFile: Sendable, Codable, Identifiable, Equatable, Hashable {
    public var id: String { "\(status):\(path)" }
    public let status: String
    public let path: String

    public init(status: String, path: String) {
        self.status = status
        self.path = path
    }
}

public struct GitDetail: Sendable, Codable, Equatable {
    public let isGitRepo: Bool
    public let branch: String?
    public let changedFiles: [GitChangedFile]
    public let diff: String

    public init(isGitRepo: Bool, branch: String?, changedFiles: [GitChangedFile], diff: String) {
        self.isGitRepo = isGitRepo
        self.branch = branch
        self.changedFiles = changedFiles
        self.diff = diff
    }
}

// MARK: - Settings & MCP

public struct MCPServerSummary: Sendable, Codable, Identifiable, Equatable, Hashable {
    public var id: String { name }
    public let name: String
    public let transport: String
    public let target: String
    public let enabled: Bool

    public init(name: String, transport: String, target: String, enabled: Bool) {
        self.name = name
        self.transport = transport
        self.target = target
        self.enabled = enabled
    }
}

public struct ModelOption: Sendable, Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct RemoteSettings: Sendable, Codable, Equatable {
    public let modelProvider: String
    public let permissionMode: String
    public let selectedModel: String
    public let cliDefaultModel: String?
    public let availableModels: [ModelOption]
    public let agentMode: String
    public let cliAgentMode: String?
    public let readOnlyCliConfig: Bool
    public let trustedWorkspaces: [String]
    public let mcpServers: [MCPServerSummary]
    public let configPath: String

    public init(
        modelProvider: String,
        permissionMode: String,
        selectedModel: String = "default",
        cliDefaultModel: String? = nil,
        availableModels: [ModelOption] = [],
        agentMode: String = "default",
        cliAgentMode: String? = nil,
        readOnlyCliConfig: Bool = true,
        trustedWorkspaces: [String],
        mcpServers: [MCPServerSummary],
        configPath: String
    ) {
        self.modelProvider = modelProvider
        self.permissionMode = permissionMode
        self.selectedModel = selectedModel
        self.cliDefaultModel = cliDefaultModel
        self.availableModels = availableModels
        self.agentMode = agentMode
        self.cliAgentMode = cliAgentMode
        self.readOnlyCliConfig = readOnlyCliConfig
        self.trustedWorkspaces = trustedWorkspaces
        self.mcpServers = mcpServers
        self.configPath = configPath
    }

    public enum CodingKeys: String, CodingKey {
        case modelProvider, permissionMode, selectedModel, cliDefaultModel, availableModels
        case agentMode, cliAgentMode, readOnlyCliConfig, trustedWorkspaces, mcpServers, configPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelProvider = try c.decodeIfPresent(String.self, forKey: .modelProvider) ?? "default"
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? "default"
        selectedModel = try c.decodeIfPresent(String.self, forKey: .selectedModel) ?? "default"
        cliDefaultModel = try c.decodeIfPresent(String.self, forKey: .cliDefaultModel)
        availableModels = try c.decodeIfPresent([ModelOption].self, forKey: .availableModels) ?? []
        agentMode = try c.decodeIfPresent(String.self, forKey: .agentMode) ?? "default"
        cliAgentMode = try c.decodeIfPresent(String.self, forKey: .cliAgentMode)
        readOnlyCliConfig = try c.decodeIfPresent(Bool.self, forKey: .readOnlyCliConfig) ?? true
        trustedWorkspaces = try c.decodeIfPresent([String].self, forKey: .trustedWorkspaces) ?? []
        mcpServers = try c.decodeIfPresent([MCPServerSummary].self, forKey: .mcpServers) ?? []
        configPath = try c.decodeIfPresent(String.self, forKey: .configPath) ?? ""
    }
}

public struct RemoteSettingsPatch: Sendable, Codable, Equatable {
    public var modelProvider: String?
    public var permissionMode: String?
    public var selectedModel: String?
    public var agentMode: String?

    public init(
        modelProvider: String? = nil,
        permissionMode: String? = nil,
        selectedModel: String? = nil,
        agentMode: String? = nil
    ) {
        self.modelProvider = modelProvider
        self.permissionMode = permissionMode
        self.selectedModel = selectedModel
        self.agentMode = agentMode
    }
}

// MARK: - WebSocket Stream Events

public enum BridgeStreamEvent: Sendable, Equatable {
    case connected(serverTime: Date, daemon: DaemonStatus?)
    case runStarted(runId: String, sessionId: String, messageId: String, prompt: String)
    case messageDelta(runId: String, sessionId: String, messageId: String, delta: String)
    case toolEvent(runId: String, sessionId: String, messageId: String, event: ToolActivityEvent)
    case runCompleted(runId: String, sessionId: String, messageId: String, message: ChatMessage?)
    case runFailed(runId: String, sessionId: String, messageId: String, error: String)
    case runCancelled(runId: String, sessionId: String, messageId: String)
    case daemonUpdated(daemon: DaemonStatus)
    case pong(serverTime: Date)
    case unknown(type: String)

    private struct RawEnvelope: Decodable {
        let type: String
        let serverTime: Date?
        let runId: String?
        let sessionId: String?
        let messageId: String?
        let prompt: String?
        let delta: String?
        let event: ToolActivityEvent?
        let message: ChatMessage?
        let error: String?
        let daemon: DaemonStatus?
    }

    public static func decode(from data: Data) throws -> BridgeStreamEvent {
        let env = try BridgeJSON.decoder.decode(RawEnvelope.self, from: data)
        switch env.type {
        case "connected":
            return .connected(serverTime: env.serverTime ?? Date(), daemon: env.daemon)
        case "run.started":
            return .runStarted(
                runId: env.runId ?? "",
                sessionId: env.sessionId ?? "",
                messageId: env.messageId ?? "",
                prompt: env.prompt ?? ""
            )
        case "message.delta":
            return .messageDelta(
                runId: env.runId ?? "",
                sessionId: env.sessionId ?? "",
                messageId: env.messageId ?? "",
                delta: env.delta ?? ""
            )
        case "tool.event":
            guard let event = env.event else { return .unknown(type: env.type) }
            return .toolEvent(
                runId: env.runId ?? "",
                sessionId: env.sessionId ?? "",
                messageId: env.messageId ?? "",
                event: event
            )
        case "run.completed":
            return .runCompleted(
                runId: env.runId ?? "",
                sessionId: env.sessionId ?? "",
                messageId: env.messageId ?? "",
                message: env.message
            )
        case "run.failed":
            return .runFailed(
                runId: env.runId ?? "",
                sessionId: env.sessionId ?? "",
                messageId: env.messageId ?? "",
                error: env.error ?? "Run failed"
            )
        case "run.cancelled":
            return .runCancelled(
                runId: env.runId ?? "",
                sessionId: env.sessionId ?? "",
                messageId: env.messageId ?? ""
            )
        case "daemon.updated":
            guard let daemon = env.daemon else { return .unknown(type: env.type) }
            return .daemonUpdated(daemon: daemon)
        case "pong":
            return .pong(serverTime: env.serverTime ?? Date())
        default:
            return .unknown(type: env.type)
        }
    }
}

// MARK: - Errors & JSON Coding

public enum BridgeError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case invalidPairingURI(String)
    case unauthorized
    case serverError(statusCode: Int, message: String)
    case networkFailure(String)
    case decodingFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "Invalid server URL: \(raw)"
        case .invalidPairingURI(let detail):
            return detail
        case .unauthorized:
            return "Authentication rejected. Re-pair or update the host token in Settings."
        case .serverError(let code, let message):
            return "Server returned \(code): \(message)"
        case .networkFailure(let detail):
            return "Connection failed: \(detail)"
        case .decodingFailure(let detail):
            return "Unexpected server response: \(detail)"
        }
    }
}

public enum BridgeJSON {
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: string) {
                return date
            }
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let date = basic.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date string: \(string)"
            )
        }
        return decoder
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
