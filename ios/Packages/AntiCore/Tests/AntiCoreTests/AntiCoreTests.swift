import Foundation
import Testing
@testable import AntiCore

@Suite("AntiCore Models, Pairing & Demo Streaming")
struct AntiCoreTests {
    @Test("Parses valid antiremote:// pairing URI with fingerprint")
    func parsesValidPairingURI() throws {
        let uri = "antiremote://pair?url=https%3A%2F%2F100.64.0.10%3A8787&code=ab12-cd34&name=Workstation&fp=deadbeef"
        let payload = try PairingPayload.parse(uri: uri)
        #expect(payload.baseURL.absoluteString == "https://100.64.0.10:8787")
        #expect(payload.code == "AB12-CD34")
        #expect(payload.hostName == "Workstation")
        #expect(payload.tlsFingerprint == "deadbeef")
    }

    @Test("Rejects malformed pairing URIs", arguments: [
        "https://example.com/pair?url=http://127.0.0.1:8787&code=ABCD-1234",
        "antiremote://pair?url=ftp://127.0.0.1&code=ABCD-1234",
        "antiremote://pair?url=http://127.0.0.1:8787",
        "antiremote://other?url=http://127.0.0.1:8787&code=ABCD-1234",
    ])
    func rejectsInvalidPairingURI(badURI: String) {
        #expect(throws: BridgeError.self) {
            _ = try PairingPayload.parse(uri: badURI)
        }
    }

    @Test("Decodes fractional-second ISO-8601 bridge status payload")
    func decodesFractionalISO8601Status() throws {
        let json = """
        {
          "hostname": "dev-box",
          "platform": "linux-x64",
          "uptimeSeconds": 420,
          "serverVersion": "1.0.0",
          "adapter": "agy",
          "agyInstalled": true,
          "agyVersion": "2.1.0",
          "daemon": {
            "state": "running",
            "url": "https://antigravity.google/rc/1",
            "detail": "active",
            "updatedAt": "2026-11-26T09:45:12.345Z"
          },
          "activeRunsCount": 1,
          "workspacesCount": 2,
          "modelProvider": "gemini",
          "permissionMode": "ask"
        }
        """
        let status = try BridgeJSON.decoder.decode(HostStatus.self, from: Data(json.utf8))
        #expect(status.hostname == "dev-box")
        #expect(status.daemon.state == .running)
        #expect(status.agyInstalled)
    }

    @Test("Stores host profiles separately from bearer tokens")
    func hostProfileAndTokenSeparation() throws {
        let suite = "com.antiremote.tests.\(UUID().uuidString)"
        let tokens = InMemoryTokenStore()
        let repo = HostProfileRepository(suiteName: suite, tokenStore: tokens)

        let host = HostProfile(name: "Lab Linux", baseURLString: "http://192.168.1.50:8787")
        let saved = try repo.upsert(profile: host, token: "super-secret-bearer-token")
        #expect(saved.contains(where: { $0.id == host.id }))
        #expect(try tokens.token(for: host.id) == "super-secret-bearer-token")

        // Ensure UserDefaults never holds the raw secret token
        let rawDefaults = UserDefaults(suiteName: suite)?.data(forKey: "antiremote.hosts.v1")
        let encodedString = rawDefaults.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!encodedString.contains("super-secret-bearer-token"))

        _ = try repo.remove(hostID: host.id)
        #expect(try tokens.token(for: host.id) == nil)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test("Demo client streams deltas and completes run")
    func demoClientStreamingFlow() async throws {
        let client = BridgeClient.demo()
        let sessions = try await client.sessions()
        let session = try #require(sessions.first)

        let stream = client.streamEvents()
        let collectTask = Task<[BridgeStreamEvent], any Error> {
            var collected: [BridgeStreamEvent] = []
            for try await event in stream {
                collected.append(event)
                if case .runCompleted = event { break }
            }
            return collected
        }

        try await Task.sleep(for: .milliseconds(30))
        let dispatched = try await client.sendMessage(session.id, "/plan Verify build", "/plan", session.workspaceId)
        #expect(!dispatched.runId.isEmpty)

        let events = try await collectTask.value
        #expect(events.contains(where: { if case .messageDelta = $0 { return true }; return false }))
        #expect(events.contains(where: { if case .runCompleted = $0 { return true }; return false }))
    }

    @Test("Decodes both legacy and v1.2 RemoteSettings payloads safely")
    func decodesLegacyAndModernRemoteSettings() throws {
        let legacyJSON = """
        {
          "modelProvider": "gemini",
          "permissionMode": "ask",
          "trustedWorkspaces": ["/srv/app"],
          "mcpServers": [],
          "configPath": "~/.gemini/antigravity-cli/settings.json"
        }
        """
        let legacy = try BridgeJSON.decoder.decode(RemoteSettings.self, from: Data(legacyJSON.utf8))
        #expect(legacy.selectedModel == "default")
        #expect(legacy.agentMode == "default")
        #expect(legacy.availableModels.isEmpty)
        #expect(legacy.readOnlyCliConfig)

        let modernJSON = """
        {
          "modelProvider": "gemini-4-neon-high",
          "permissionMode": "accept-edits",
          "selectedModel": "gemini-4-neon-high",
          "cliDefaultModel": "gemini-3.8-flash-high",
          "availableModels": [
            { "id": "gemini-4-neon-high", "label": "Gemini 4 Neon (High)" }
          ],
          "agentMode": "accept-edits",
          "cliAgentMode": "plan",
          "readOnlyCliConfig": true,
          "trustedWorkspaces": ["/srv/app"],
          "mcpServers": [],
          "configPath": "~/.gemini/antigravity-cli/settings.json"
        }
        """
        let modern = try BridgeJSON.decoder.decode(RemoteSettings.self, from: Data(modernJSON.utf8))
        #expect(modern.selectedModel == "gemini-4-neon-high")
        #expect(modern.cliDefaultModel == "gemini-3.8-flash-high")
        #expect(modern.availableModels.count == 1)
        #expect(modern.agentMode == "accept-edits")
        #expect(modern.cliAgentMode == "plan")
    }
}
