import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';

import { createAdapter } from './agy-adapter.mjs';
import {
  BRIDGE_VERSION,
  buildPairingURI,
  detectAdvertiseHost,
  generatePairingCode,
  loadOrCreateToken,
  normalizeWorkspaces,
} from './config.mjs';
import {
  HttpError,
  RateLimiter,
  constantTimeTokenEqual,
  extractBearerToken,
  readJsonBody,
} from './security.mjs';
import { readRemoteSettings, updateRemoteSettings } from './settings.mjs';
import { BUILTIN_SLASH_COMMANDS, BridgeStore } from './store.mjs';
import {
  inspectWorkspaceGitDetail,
  inspectWorkspaceGitSummary,
  listWorkspaceFiles,
  readWorkspaceFile,
} from './workspace.mjs';
import { WebSocketHub } from './ws.mjs';

const PAIRING_TTL_MS = 10 * 60 * 1000; // 10 minutes

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(body);
}

/**
 * Creates a fully configured AntiRemote Bridge HTTP(S) + WebSocket server.
 */
export async function createBridgeServer(options = {}) {
  const host = options.host || '0.0.0.0';
  const port = options.port ?? 8787;
  const hostName = options.hostName || os.hostname();
  const stateDir = options.stateDir ?? path.join(process.cwd(), '.bridge-state');
  const token = await loadOrCreateToken(stateDir, options.token);
  const workspaces = await normalizeWorkspaces(options.workspaces || [process.cwd()]);
  const { adapter, probe } = await createAdapter(options.adapter || 'auto', {
    binary: options.agyBinary || 'agy',
    allowSkipPermissions: Boolean(options.allowSkipPermissions),
  });

  const store = new BridgeStore(options.persistSessions === false ? null : stateDir);
  await store.load(workspaces[0]?.id);

  let daemonStatus = await adapter.daemonCommand('status');
  const startedAtMs = Date.now();
  const pairLimiter = new RateLimiter({ maxAttempts: 10, windowMs: 60_000 });
  const activePairingCodes = new Map(); // normalizedCode -> { expiresAt }

  function issuePairingCode() {
    const now = Date.now();
    for (const [k, v] of activePairingCodes.entries()) {
      if (v.expiresAt <= now) activePairingCodes.delete(k);
    }
    const code = generatePairingCode();
    const expiresAt = now + PAIRING_TTL_MS;
    activePairingCodes.set(code, { expiresAt });
    return { code, expiresAt: new Date(expiresAt).toISOString() };
  }

  let initialPairing = issuePairingCode();
  let tlsFingerprint = null;
  let scheme = 'http';

  const isAuthorizedRequest = (req, { allowQuery = false } = {}) => {
    const candidate = extractBearerToken(req, { allowQuery });
    return constantTimeTokenEqual(token, candidate);
  };

  const wsHub = new WebSocketHub({
    authenticate: (req) => isAuthorizedRequest(req, { allowQuery: true }),
    onConnect: (client) => {
      client.sendJSON({
        type: 'connected',
        serverTime: new Date().toISOString(),
        activeRuns: store.listRuns().filter((r) => r.status === 'running'),
        daemon: daemonStatus,
      });
    },
    onMessage: (client, text) => {
      try {
        const msg = JSON.parse(text);
        if (msg?.type === 'ping') {
          client.sendJSON({ type: 'pong', serverTime: new Date().toISOString() });
        }
      } catch {
        // Ignore malformed client WS messages
      }
    },
  });

  function resolveWorkspaceById(id) {
    if (!id) return workspaces[0] || null;
    return workspaces.find((w) => w.id === id) || null;
  }

  async function handleRequest(req, res) {
    const parsedUrl = new URL(req.url || '/', 'http://localhost');
    const pathname = parsedUrl.pathname;
    const method = (req.method || 'GET').toUpperCase();

    try {
      // 1. Minimal unauthenticated health check
      if (method === 'GET' && pathname === '/v1/health') {
        return sendJson(res, 200, {
          ok: true,
          service: 'antiremote-bridge',
          version: BRIDGE_VERSION,
          requiresAuth: true,
          timestamp: new Date().toISOString(),
        });
      }

      // 2. Rate-limited one-time pairing claim
      if (method === 'POST' && pathname === '/v1/pair/claim') {
        const remoteIp = req.socket?.remoteAddress || 'unknown';
        const verdict = pairLimiter.check(remoteIp);
        if (!verdict.allowed) {
          return sendJson(res, 429, { error: 'Too many pairing attempts. Retry shortly.' });
        }
        const body = await readJsonBody(req);
        const submitted = typeof body.code === 'string' ? body.code.trim().toUpperCase() : '';
        const record = activePairingCodes.get(submitted);
        if (!record || record.expiresAt <= Date.now()) {
          activePairingCodes.delete(submitted);
          return sendJson(res, 401, { error: 'Invalid or expired pairing code.' });
        }
        // Single-use burn
        activePairingCodes.delete(submitted);
        return sendJson(res, 200, {
          token,
          hostName,
          serverVersion: BRIDGE_VERSION,
          adapter: adapter.mode,
        });
      }

      // Everything below requires valid Bearer auth
      if (!isAuthorizedRequest(req, { allowQuery: false })) {
        return sendJson(res, 401, { error: 'Unauthorized. Provide Authorization: Bearer <token>.' });
      }

      // 3. Issue fresh pairing code (authenticated)
      if (method === 'POST' && pathname === '/v1/pair/create') {
        const issued = issuePairingCode();
        const advHost = detectAdvertiseHost(host);
        const boundPort = server.address()?.port ?? port;
        const baseUrl = `${scheme}://${advHost}:${boundPort}`;
        return sendJson(res, 200, {
          code: issued.code,
          expiresAt: issued.expiresAt,
          pairingURI: buildPairingURI({
            baseUrl,
            code: issued.code,
            hostName,
            fingerprint: tlsFingerprint,
          }),
        });
      }

      // 4. Host & daemon status
      if (method === 'GET' && pathname === '/v1/status') {
        const settings = await readRemoteSettings({
          settingsPath: options.agySettingsPath,
          workspaces,
          mcpConfigPath: options.mcpConfigPath,
        });
        return sendJson(res, 200, {
          hostname: hostName,
          platform: `${process.platform}-${process.arch}`,
          uptimeSeconds: Math.floor((Date.now() - startedAtMs) / 1000),
          serverVersion: BRIDGE_VERSION,
          adapter: adapter.mode,
          agyInstalled: probe.installed,
          agyVersion: probe.version,
          daemon: daemonStatus,
          activeRunsCount: store.activeRunsCount(),
          workspacesCount: workspaces.length,
          modelProvider: settings.modelProvider,
          permissionMode: settings.permissionMode,
        });
      }

      // 5. Daemon control: POST /v1/daemon/:action
      const daemonMatch = pathname.match(/^\/v1\/daemon\/(start|stop|status)$/);
      if (method === 'POST' && daemonMatch) {
        const action = daemonMatch[1];
        daemonStatus = await adapter.daemonCommand(action);
        wsHub.broadcast({ type: 'daemon.updated', daemon: daemonStatus });
        return sendJson(res, 200, daemonStatus);
      }

      // 6. Slash commands catalog
      if (method === 'GET' && pathname === '/v1/commands') {
        return sendJson(res, 200, { commands: BUILTIN_SLASH_COMMANDS });
      }

      // 7. Sessions CRUD
      if (method === 'GET' && pathname === '/v1/sessions') {
        return sendJson(res, 200, { sessions: store.listSessionSummaries() });
      }

      if (method === 'POST' && pathname === '/v1/sessions') {
        const body = await readJsonBody(req);
        const ws = resolveWorkspaceById(body.workspaceId);
        if (!ws) {
          throw new HttpError(400, 'Unknown workspaceId');
        }
        const created = store.createSession({
          title: typeof body.title === 'string' ? body.title : 'New Session',
          workspaceId: ws.id,
        });
        await store.persist();
        return sendJson(res, 201, created);
      }

      const sessionMatch = pathname.match(/^\/v1\/sessions\/([a-zA-Z0-9-]+)$/);
      if (sessionMatch && method === 'GET') {
        const session = store.getSession(sessionMatch[1]);
        if (!session) throw new HttpError(404, 'Session not found');
        return sendJson(res, 200, session);
      }

      if (sessionMatch && method === 'DELETE') {
        const deleted = store.deleteSession(sessionMatch[1]);
        if (!deleted) throw new HttpError(404, 'Session not found');
        await store.persist();
        return sendJson(res, 200, { deleted: true, id: sessionMatch[1] });
      }

      // 8. Dispatch prompt / slash command in session (streams over WS)
      const msgMatch = pathname.match(/^\/v1\/sessions\/([a-zA-Z0-9-]+)\/messages$/);
      if (msgMatch && method === 'POST') {
        const session = store.getSession(msgMatch[1]);
        if (!session) throw new HttpError(404, 'Session not found');

        const body = await readJsonBody(req);
        const prompt = typeof body.prompt === 'string' ? body.prompt.trim() : '';
        const slashCommand = typeof body.slashCommand === 'string' && body.slashCommand.trim()
          ? body.slashCommand.trim()
          : null;
        if (!prompt) {
          throw new HttpError(400, 'Prompt cannot be empty');
        }
        if (prompt.length > 32_000) {
          throw new HttpError(400, 'Prompt exceeds 32,000 character limit');
        }

        const ws = resolveWorkspaceById(body.workspaceId || session.workspaceId);
        if (!ws) {
          throw new HttpError(400, 'No valid workspace configured on host');
        }
        session.workspaceId = ws.id;

        const userMessage = store.appendMessage(session.id, {
          role: 'user',
          content: prompt,
          slashCommand,
          status: 'completed',
        });

        const assistantMessage = store.appendMessage(session.id, {
          role: 'assistant',
          content: '',
          slashCommand,
          status: 'streaming',
          toolEvents: [],
        });

        const { run, controller } = store.registerRun({
          sessionId: session.id,
          workspaceId: ws.id,
          prompt,
          assistantMessageId: assistantMessage.id,
        });

        await store.persist();

        wsHub.broadcast({
          type: 'run.started',
          runId: run.id,
          sessionId: session.id,
          messageId: assistantMessage.id,
          prompt,
        });

        adapter.runPrompt({
          prompt,
          slashCommand,
          workspacePath: ws.path,
          signal: controller.signal,
          onDelta: (delta) => {
            assistantMessage.content += delta;
            wsHub.broadcast({
              type: 'message.delta',
              runId: run.id,
              sessionId: session.id,
              messageId: assistantMessage.id,
              delta,
            });
          },
          onTool: (event) => {
            const idx = assistantMessage.toolEvents.findIndex((e) => e.id === event.id);
            if (idx >= 0) {
              assistantMessage.toolEvents[idx] = event;
            } else {
              assistantMessage.toolEvents.push(event);
            }
            const runIdx = run.toolEvents.findIndex((e) => e.id === event.id);
            if (runIdx >= 0) {
              run.toolEvents[runIdx] = event;
            } else {
              run.toolEvents.push(event);
            }
            wsHub.broadcast({
              type: 'tool.event',
              runId: run.id,
              sessionId: session.id,
              messageId: assistantMessage.id,
              event,
            });
          },
          onComplete: async (finalText) => {
            const finished = store.finishRun(run.id, {
              status: 'completed',
              content: finalText,
            });
            if (!finished) return;
            await store.persist();
            wsHub.broadcast({
              type: 'run.completed',
              runId: run.id,
              sessionId: session.id,
              messageId: assistantMessage.id,
              message: finished.message,
            });
          },
          onError: async (errorMsg) => {
            const finished = store.finishRun(run.id, {
              status: 'failed',
              content: assistantMessage.content || `Error: ${errorMsg}`,
              error: errorMsg,
            });
            if (!finished) return;
            await store.persist();
            wsHub.broadcast({
              type: 'run.failed',
              runId: run.id,
              sessionId: session.id,
              messageId: assistantMessage.id,
              error: errorMsg,
            });
          },
        });

        return sendJson(res, 202, {
          runId: run.id,
          sessionId: session.id,
          userMessage,
          assistantMessage,
        });
      }

      // 9. Runs list & cancel
      if (method === 'GET' && pathname === '/v1/runs') {
        return sendJson(res, 200, { runs: store.listRuns() });
      }

      const cancelMatch = pathname.match(/^\/v1\/runs\/([a-zA-Z0-9-]+)\/cancel$/);
      if (cancelMatch && method === 'POST') {
        const cancelled = store.cancelRun(cancelMatch[1]);
        if (!cancelled) {
          throw new HttpError(404, 'Active run not found');
        }
        await store.persist();
        wsHub.broadcast({
          type: 'run.cancelled',
          runId: cancelled.id,
          sessionId: cancelled.sessionId,
          messageId: cancelled.assistantMessageId,
        });
        return sendJson(res, 200, { cancelled: true, run: cancelled });
      }

      // 10. Workspaces list, files, file preview, git status/diff
      if (method === 'GET' && pathname === '/v1/workspaces') {
        const enriched = await Promise.all(
          workspaces.map(async (w) => {
            const git = await inspectWorkspaceGitSummary(w.path);
            return { ...w, ...git };
          })
        );
        return sendJson(res, 200, { workspaces: enriched });
      }

      const wsFilesMatch = pathname.match(/^\/v1\/workspaces\/([a-zA-Z0-9_-]+)\/files$/);
      if (wsFilesMatch && method === 'GET') {
        const ws = resolveWorkspaceById(wsFilesMatch[1]);
        if (!ws) throw new HttpError(404, 'Workspace not found');
        const relPath = parsedUrl.searchParams.get('path') || '';
        const listing = await listWorkspaceFiles(ws.path, relPath);
        return sendJson(res, 200, listing);
      }

      const wsFileMatch = pathname.match(/^\/v1\/workspaces\/([a-zA-Z0-9_-]+)\/file$/);
      if (wsFileMatch && method === 'GET') {
        const ws = resolveWorkspaceById(wsFileMatch[1]);
        if (!ws) throw new HttpError(404, 'Workspace not found');
        const relPath = parsedUrl.searchParams.get('path') || '';
        const fileData = await readWorkspaceFile(ws.path, relPath);
        return sendJson(res, 200, fileData);
      }

      const wsGitMatch = pathname.match(/^\/v1\/workspaces\/([a-zA-Z0-9_-]+)\/git$/);
      if (wsGitMatch && method === 'GET') {
        const ws = resolveWorkspaceById(wsGitMatch[1]);
        if (!ws) throw new HttpError(404, 'Workspace not found');
        const gitDetail = await inspectWorkspaceGitDetail(ws.path);
        return sendJson(res, 200, gitDetail);
      }

      // 11. Settings & MCP inspection/update
      if (method === 'GET' && pathname === '/v1/settings') {
        const settings = await readRemoteSettings({
          settingsPath: options.agySettingsPath,
          workspaces,
          mcpConfigPath: options.mcpConfigPath,
        });
        return sendJson(res, 200, settings);
      }

      if (method === 'PATCH' && pathname === '/v1/settings') {
        const body = await readJsonBody(req);
        const updated = await updateRemoteSettings({
          settingsPath: options.agySettingsPath,
          patch: body,
          workspaces,
          mcpConfigPath: options.mcpConfigPath,
        });
        return sendJson(res, 200, updated);
      }

      return sendJson(res, 404, { error: `Route not found: ${method} ${pathname}` });
    } catch (err) {
      if (err instanceof HttpError) {
        return sendJson(res, err.status, { error: err.message });
      }
      return sendJson(res, 500, { error: 'Internal bridge error' });
    }
  }

  let server;
  if (options.tlsCertPath && options.tlsKeyPath) {
    const [cert, key] = await Promise.all([
      fs.readFile(options.tlsCertPath),
      fs.readFile(options.tlsKeyPath),
    ]);
    const x509 = new crypto.X509Certificate(cert);
    tlsFingerprint = x509.fingerprint256.replace(/:/g, '').toLowerCase();
    scheme = 'https';
    server = https.createServer({ cert, key }, handleRequest);
  } else {
    server = http.createServer(handleRequest);
  }

  wsHub.attach(server, '/v1/stream');

  return {
    server,
    wsHub,
    token,
    workspaces,
    adapterMode: adapter.mode,
    async start() {
      await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => {
          server.off('error', reject);
          resolve();
        });
      });
      const address = server.address();
      const actualPort = typeof address === 'object' && address ? address.port : port;
      const advHost = detectAdvertiseHost(host);
      const baseUrl = `${scheme}://${advHost}:${actualPort}`;
      return {
        host,
        advertiseHost: advHost,
        port: actualPort,
        scheme,
        baseUrl,
        pairingCode: initialPairing.code,
        pairingExpiresAt: initialPairing.expiresAt,
        pairingURI: buildPairingURI({
          baseUrl,
          code: initialPairing.code,
          hostName,
          fingerprint: tlsFingerprint,
        }),
        tlsFingerprint,
        adapterMode: adapter.mode,
        agyInstalled: probe.installed,
      };
    },
    async stop() {
      wsHub.closeAll();
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}
