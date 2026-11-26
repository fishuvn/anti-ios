import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';

import { encodeQRMatrix, renderTerminalQR } from '../src/qrcode.mjs';
import { createBridgeServer } from '../src/server.mjs';
import { encodeFrame } from '../src/ws.mjs';

/**
 * Minimal RFC 6455 test client over raw TCP to verify live WebSocket streaming without external deps.
 */
function connectTestWS({ port, token }) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port }, () => {
      const key = crypto.randomBytes(16).toString('base64');
      socket.write([
        'GET /v1/stream HTTP/1.1',
        `Host: 127.0.0.1:${port}`,
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Authorization: Bearer ${token}`,
        `Sec-WebSocket-Key: ${key}`,
        'Sec-WebSocket-Version: 13',
        '\r\n',
      ].join('\r\n'));
    });

    let upgraded = false;
    let buf = Buffer.alloc(0);
    const events = [];
    const waiters = [];

    const flushWaiters = () => {
      for (let i = waiters.length - 1; i >= 0; i -= 1) {
        const w = waiters[i];
        const match = events.find(w.predicate);
        if (match) {
          waiters.splice(i, 1);
          clearTimeout(w.timer);
          w.resolve(match);
        }
      }
    };

    socket.on('error', reject);
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (!upgraded) {
        const idx = buf.indexOf('\r\n\r\n');
        if (idx === -1) return;
        const head = buf.subarray(0, idx).toString('utf8');
        if (!head.startsWith('HTTP/1.1 101')) {
          reject(new Error(`WS handshake failed: ${head.split('\r\n')[0]}`));
          socket.destroy();
          return;
        }
        upgraded = true;
        buf = buf.subarray(idx + 4);
        resolve({
          events,
          waitFor(predicate, timeoutMs = 4000) {
            const existing = events.find(predicate);
            if (existing) return Promise.resolve(existing);
            return new Promise((res, rej) => {
              const timer = setTimeout(() => rej(new Error('Timed out waiting for WS event')), timeoutMs);
              waiters.push({ predicate, resolve: res, timer });
            });
          },
          close() {
            socket.end(encodeFrame(0x8));
          },
        });
      }

      while (buf.length >= 2) {
        const opcode = buf[0] & 0x0f;
        let len = buf[1] & 0x7f;
        let offset = 2;
        if (len === 126) {
          if (buf.length < 4) return;
          len = buf.readUInt16BE(2);
          offset = 4;
        } else if (len === 127) {
          if (buf.length < 10) return;
          len = Number(buf.readBigUInt64BE(2));
          offset = 10;
        }
        if (buf.length < offset + len) return;
        const payload = buf.subarray(offset, offset + len);
        buf = buf.subarray(offset + len);
        if (opcode === 0x1) {
          events.push(JSON.parse(payload.toString('utf8')));
          flushWaiters();
        }
      }
    });
  });
}

describe('AntiRemote Bridge API & WebSocket E2E', () => {
  let tmpDir;
  let workspaceDir;
  let outsideFile;
  let bridge;
  let info;
  let bearerToken;

  before(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'antiremote-test-'));
    workspaceDir = path.join(tmpDir, 'workspace');
    await fs.mkdir(path.join(workspaceDir, 'src'), { recursive: true });
    await fs.writeFile(path.join(workspaceDir, 'README.md'), '# Sample Workspace\nHello AntiRemote\n');
    await fs.writeFile(path.join(workspaceDir, 'src', 'app.swift'), 'struct App {}\n');
    await fs.writeFile(
      path.join(workspaceDir, 'mcp_config.json'),
      JSON.stringify({
        mcpServers: {
          demoMcp: {
            serverUrl: 'https://mcp.example.internal/sse',
            env: { SUPER_SECRET_API_KEY: 'should-never-leak' },
          },
        },
      })
    );

    // Create outside file + symlink escape trap inside workspace
    outsideFile = path.join(tmpDir, 'secret-outside.txt');
    await fs.writeFile(outsideFile, 'TOP_SECRET_OUTSIDE');
    await fs.symlink(outsideFile, path.join(workspaceDir, 'escape-link.txt'));

    bridge = await createBridgeServer({
      host: '127.0.0.1',
      port: 0,
      hostName: 'test-rig',
      workspaces: [workspaceDir],
      adapter: 'mock',
      stateDir: path.join(tmpDir, 'state'),
      agySettingsPath: path.join(tmpDir, 'agy-settings.json'),
      mcpConfigPath: path.join(workspaceDir, 'mcp_config.json'),
    });
    info = await bridge.start();
  });

  after(async () => {
    if (bridge) await bridge.stop();
    if (tmpDir) await fs.rm(tmpDir, { recursive: true, force: true });
  });

  it('exposes minimal unauthenticated health and blocks protected routes without token', async () => {
    const healthRes = await fetch(`http://127.0.0.1:${info.port}/v1/health`);
    assert.equal(healthRes.status, 200);
    const health = await healthRes.json();
    assert.equal(health.ok, true);
    assert.equal(health.requiresAuth, true);

    const statusUnauth = await fetch(`http://127.0.0.1:${info.port}/v1/status`);
    assert.equal(statusUnauth.status, 401);
  });

  it('claims one-time pairing code once and burns it on replay', async () => {
    const claimRes = await fetch(`http://127.0.0.1:${info.port}/v1/pair/claim`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: info.pairingCode }),
    });
    assert.equal(claimRes.status, 200);
    const claimed = await claimRes.json();
    assert.equal(claimed.hostName, 'test-rig');
    assert.equal(claimed.adapter, 'mock');
    assert.ok(claimed.token.length >= 32);
    bearerToken = claimed.token;

    // Replay must be rejected
    const replayRes = await fetch(`http://127.0.0.1:${info.port}/v1/pair/claim`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: info.pairingCode }),
    });
    assert.equal(replayRes.status, 401);
  });

  it('returns status, toggles daemon start/stop, and lists slash commands', async () => {
    const headers = { Authorization: `Bearer ${bearerToken}` };

    const statusRes = await fetch(`http://127.0.0.1:${info.port}/v1/status`, { headers });
    assert.equal(statusRes.status, 200);
    const status = await statusRes.json();
    assert.equal(status.hostname, 'test-rig');
    assert.equal(status.daemon.state, 'running');

    const stopRes = await fetch(`http://127.0.0.1:${info.port}/v1/daemon/stop`, { method: 'POST', headers });
    assert.equal(stopRes.status, 200);
    const stopped = await stopRes.json();
    assert.equal(stopped.state, 'stopped');

    const startRes = await fetch(`http://127.0.0.1:${info.port}/v1/daemon/start`, { method: 'POST', headers });
    assert.equal(startRes.status, 200);
    const started = await startRes.json();
    assert.equal(started.state, 'running');

    const cmdRes = await fetch(`http://127.0.0.1:${info.port}/v1/commands`, { headers });
    assert.equal(cmdRes.status, 200);
    const { commands } = await cmdRes.json();
    assert.ok(commands.some((c) => c.command === '/plan'));
    assert.ok(commands.some((c) => c.command === '/agents'));
  });

  it('streams chat response and tool events over WebSocket and persists session', async () => {
    const headers = {
      Authorization: `Bearer ${bearerToken}`,
      'Content-Type': 'application/json',
    };

    const ws = await connectTestWS({ port: info.port, token: bearerToken });
    const connected = await ws.waitFor((e) => e.type === 'connected');
    assert.equal(connected.type, 'connected');

    const createRes = await fetch(`http://127.0.0.1:${info.port}/v1/sessions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ title: 'Operator Test' }),
    });
    assert.equal(createRes.status, 201);
    const session = await createRes.json();

    const msgRes = await fetch(`http://127.0.0.1:${info.port}/v1/sessions/${session.id}/messages`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ prompt: '/plan Ship iOS app', slashCommand: '/plan' }),
    });
    assert.equal(msgRes.status, 202);
    const dispatched = await msgRes.json();

    const deltaEvent = await ws.waitFor((e) => e.type === 'message.delta' && e.runId === dispatched.runId);
    assert.ok(deltaEvent.delta.length > 0);

    const toolEvent = await ws.waitFor((e) => e.type === 'tool.event' && e.runId === dispatched.runId);
    assert.equal(toolEvent.event.name, 'slash:/plan');

    const doneEvent = await ws.waitFor((e) => e.type === 'run.completed' && e.runId === dispatched.runId);
    assert.equal(doneEvent.message.status, 'completed');
    assert.ok(doneEvent.message.content.includes('Execution plan drafted'));

    ws.close();

    const fetchedRes = await fetch(`http://127.0.0.1:${info.port}/v1/sessions/${session.id}`, { headers });
    const fetched = await fetchedRes.json();
    assert.equal(fetched.messages.length, 2);
  });

  it('cancels an active run cleanly', async () => {
    const headers = {
      Authorization: `Bearer ${bearerToken}`,
      'Content-Type': 'application/json',
    };
    const listRes = await fetch(`http://127.0.0.1:${info.port}/v1/sessions`, { headers });
    const { sessions } = await listRes.json();
    const sessionId = sessions[0].id;

    const msgRes = await fetch(`http://127.0.0.1:${info.port}/v1/sessions/${sessionId}/messages`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ prompt: 'Long streaming run to cancel' }),
    });
    const { runId } = await msgRes.json();

    const cancelRes = await fetch(`http://127.0.0.1:${info.port}/v1/runs/${runId}/cancel`, {
      method: 'POST',
      headers,
    });
    assert.equal(cancelRes.status, 200);
    const payload = await cancelRes.json();
    assert.equal(payload.cancelled, true);
    assert.equal(payload.run.status, 'cancelled');
  });

  it('jails workspace files strictly and rejects traversal and symlink escapes', async () => {
    const headers = { Authorization: `Bearer ${bearerToken}` };
    const wsRes = await fetch(`http://127.0.0.1:${info.port}/v1/workspaces`, { headers });
    const { workspaces } = await wsRes.json();
    const wsId = workspaces[0].id;

    // Valid directory & file reads
    const filesRes = await fetch(`http://127.0.0.1:${info.port}/v1/workspaces/${wsId}/files`, { headers });
    assert.equal(filesRes.status, 200);
    const listing = await filesRes.json();
    assert.ok(listing.entries.some((e) => e.name === 'README.md'));
    assert.ok(!listing.entries.some((e) => e.name === 'escape-link.txt'));

    const readmeRes = await fetch(
      `http://127.0.0.1:${info.port}/v1/workspaces/${wsId}/file?path=README.md`,
      { headers }
    );
    assert.equal(readmeRes.status, 200);
    const readme = await readmeRes.json();
    assert.ok(readme.content.includes('Hello AntiRemote'));

    // Traversal attack blocked
    const travRes = await fetch(
      `http://127.0.0.1:${info.port}/v1/workspaces/${wsId}/file?path=../secret-outside.txt`,
      { headers }
    );
    assert.equal(travRes.status, 403);

    // Symlink escape blocked
    const symRes = await fetch(
      `http://127.0.0.1:${info.port}/v1/workspaces/${wsId}/file?path=escape-link.txt`,
      { headers }
    );
    assert.equal(symRes.status, 403);
  });

  it('reads/patches settings with strict validation and redacts MCP secrets', async () => {
    const headers = {
      Authorization: `Bearer ${bearerToken}`,
      'Content-Type': 'application/json',
    };

    const getRes = await fetch(`http://127.0.0.1:${info.port}/v1/settings`, { headers });
    assert.equal(getRes.status, 200);
    const settings = await getRes.json();
    assert.equal(settings.mcpServers.length, 1);
    assert.equal(settings.mcpServers[0].name, 'demoMcp');
    assert.ok(!JSON.stringify(settings).includes('should-never-leak'));

    const patchRes = await fetch(`http://127.0.0.1:${info.port}/v1/settings`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ modelProvider: 'vertex', permissionMode: 'strict' }),
    });
    assert.equal(patchRes.status, 200);
    const patched = await patchRes.json();
    assert.equal(patched.modelProvider, 'vertex');
    assert.equal(patched.permissionMode, 'strict');

    const badPatch = await fetch(`http://127.0.0.1:${info.port}/v1/settings`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ permissionMode: 'invalid-mode' }),
    });
    assert.equal(badPatch.status, 400);
  });

  it('encodes pairing URI into valid QR matrix and terminal half-blocks', () => {
    const qr = encodeQRMatrix(info.pairingURI);
    assert.ok(qr.version >= 1 && qr.version <= 10);
    assert.equal(qr.matrix.length, qr.size);
    // Top-left finder pattern corner is always dark
    assert.equal(qr.matrix[0][0], true);
    assert.equal(qr.matrix[3][3], true);
    const rendered = renderTerminalQR(info.pairingURI);
    assert.ok(rendered.includes('█'));
  });
});
