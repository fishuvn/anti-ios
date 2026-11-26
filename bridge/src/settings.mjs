import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { HttpError } from './security.mjs';

export const ALLOWED_PERMISSION_MODES = ['ask', 'allow-read', 'strict'];
export const ALLOWED_MODEL_PROVIDERS = ['gemini', 'vertex', 'openai-compatible', 'anthropic', 'default'];

/**
 * Default documented Antigravity CLI settings path (~/.gemini/antigravity-cli/settings.json).
 */
export function defaultAgySettingsPath() {
  return path.join(os.homedir(), '.gemini', 'antigravity-cli', 'settings.json');
}

async function readJsonSafe(filePath) {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return null;
  }
}

/**
 * Reads MCP server entries from workspace or user mcp_config.json without leaking env secrets.
 */
export async function inspectMcpServers(workspaces = [], explicitMcpPath = null) {
  const candidates = [];
  if (explicitMcpPath) candidates.push(explicitMcpPath);
  for (const ws of workspaces) {
    candidates.push(path.join(ws.path, 'mcp_config.json'));
  }
  candidates.push(path.join(os.homedir(), '.gemini', 'antigravity', 'mcp_config.json'));

  const seen = new Set();
  const servers = [];

  for (const candidate of candidates) {
    const parsed = await readJsonSafe(candidate);
    if (!parsed) continue;
    const map = parsed.mcpServers && typeof parsed.mcpServers === 'object' ? parsed.mcpServers : {};
    for (const [name, cfg] of Object.entries(map)) {
      if (seen.has(name) || !cfg || typeof cfg !== 'object') continue;
      seen.add(name);
      const transport = cfg.serverUrl || cfg.url ? 'http-sse' : 'stdio';
      const target = cfg.serverUrl
        ? String(cfg.serverUrl)
        : cfg.url
          ? String(cfg.url)
          : String(cfg.command || 'configured');
      servers.push({
        name,
        transport,
        target,
        enabled: cfg.disabled !== true,
      });
    }
  }

  return servers;
}

/**
 * Loads Antigravity CLI settings plus discovered MCP servers.
 */
export async function readRemoteSettings({ settingsPath, workspaces, mcpConfigPath }) {
  const resolvedPath = settingsPath || defaultAgySettingsPath();
  const raw = (await readJsonSafe(resolvedPath)) || {};
  const mcpServers = await inspectMcpServers(workspaces, mcpConfigPath);

  return {
    modelProvider: typeof raw.modelProvider === 'string' && raw.modelProvider ? raw.modelProvider : 'gemini',
    permissionMode: typeof raw.permissionMode === 'string' && raw.permissionMode ? raw.permissionMode : 'ask',
    trustedWorkspaces: Array.isArray(raw.trustedWorkspaces)
      ? raw.trustedWorkspaces.filter((v) => typeof v === 'string')
      : workspaces.map((w) => w.path),
    mcpServers,
    configPath: resolvedPath,
  };
}

/**
 * Atomically updates validated fields in Antigravity CLI settings.json.
 */
export async function updateRemoteSettings({ settingsPath, patch, workspaces, mcpConfigPath }) {
  const resolvedPath = settingsPath || defaultAgySettingsPath();
  const existing = (await readJsonSafe(resolvedPath)) || {};
  const next = { ...existing };

  if (patch.modelProvider !== undefined) {
    if (typeof patch.modelProvider !== 'string' || !ALLOWED_MODEL_PROVIDERS.includes(patch.modelProvider)) {
      throw new HttpError(400, `Invalid modelProvider. Allowed: ${ALLOWED_MODEL_PROVIDERS.join(', ')}`);
    }
    next.modelProvider = patch.modelProvider;
  }

  if (patch.permissionMode !== undefined) {
    if (typeof patch.permissionMode !== 'string' || !ALLOWED_PERMISSION_MODES.includes(patch.permissionMode)) {
      throw new HttpError(400, `Invalid permissionMode. Allowed: ${ALLOWED_PERMISSION_MODES.join(', ')}`);
    }
    next.permissionMode = patch.permissionMode;
  }

  await fs.mkdir(path.dirname(resolvedPath), { recursive: true });
  const tmpPath = `${resolvedPath}.tmp.${process.pid}`;
  await fs.writeFile(tmpPath, `${JSON.stringify(next, null, 2)}\n`, { mode: 0o600 });
  await fs.rename(tmpPath, resolvedPath);

  return readRemoteSettings({ settingsPath: resolvedPath, workspaces, mcpConfigPath });
}
