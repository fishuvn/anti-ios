import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export const BRIDGE_VERSION = '1.0.0';

/**
 * Generates a cryptographically strong URL-safe bearer token.
 */
export function generateToken() {
  return crypto.randomBytes(32).toString('base64url');
}

/**
 * Generates a short human-readable one-time pairing code (e.g. A7K9-M2P4).
 */
export function generatePairingCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.randomBytes(8);
  let out = '';
  for (let i = 0; i < 8; i += 1) {
    if (i === 4) out += '-';
    out += alphabet[bytes[i] % alphabet.length];
  }
  return out;
}

/**
 * Loads or creates a persisted bridge token in stateDir with mode 0600.
 */
export async function loadOrCreateToken(stateDir, explicitToken) {
  if (explicitToken && explicitToken.trim().length >= 16) {
    return explicitToken.trim();
  }
  await fs.mkdir(stateDir, { recursive: true, mode: 0o700 });
  const tokenFile = path.join(stateDir, 'bridge-token');
  try {
    const existing = (await fs.readFile(tokenFile, 'utf8')).trim();
    if (existing.length >= 16) {
      return existing;
    }
  } catch (err) {
    if (err?.code !== 'ENOENT') throw err;
  }
  const fresh = generateToken();
  await fs.writeFile(tokenFile, `${fresh}\n`, { mode: 0o600 });
  return fresh;
}

/**
 * Detects the best non-loopback IPv4 LAN/Tailscale address for QR pairing hints.
 */
export function detectAdvertiseHost(bindHost) {
  if (bindHost && bindHost !== '0.0.0.0' && bindHost !== '::') {
    return bindHost;
  }
  const nets = os.networkInterfaces();
  let tailscaleCandidate = null;
  let lanCandidate = null;
  for (const [ifaceName, addrs] of Object.entries(nets)) {
    for (const addr of addrs || []) {
      if (addr.family !== 'IPv4' || addr.internal) continue;
      if (ifaceName.toLowerCase().includes('tailscale') || addr.address.startsWith('100.')) {
        tailscaleCandidate = tailscaleCandidate || addr.address;
      } else if (!lanCandidate) {
        lanCandidate = addr.address;
      }
    }
  }
  return tailscaleCandidate || lanCandidate || '127.0.0.1';
}

/**
 * Normalizes and resolves configured workspace directories.
 */
export async function normalizeWorkspaces(rawPaths) {
  const input = rawPaths && rawPaths.length > 0 ? rawPaths : [process.cwd()];
  const seen = new Set();
  const workspaces = [];

  for (const raw of input) {
    if (!raw || typeof raw !== 'string') continue;
    try {
      const resolved = await fs.realpath(path.resolve(raw));
      const stat = await fs.stat(resolved);
      if (!stat.isDirectory() || seen.has(resolved)) continue;
      seen.add(resolved);
      const id = crypto.createHash('sha256').update(resolved).digest('hex').slice(0, 12);
      workspaces.push({
        id,
        name: path.basename(resolved) || resolved,
        path: resolved,
      });
    } catch {
      // Skip nonexistent or inaccessible workspace directories.
    }
  }

  return workspaces;
}

/**
 * Builds an antiremote:// pairing URI consumable by the iOS app QR scanner.
 */
export function buildPairingURI({ baseUrl, code, hostName, fingerprint }) {
  const params = new URLSearchParams();
  params.set('url', baseUrl);
  params.set('code', code);
  params.set('name', hostName);
  if (fingerprint) {
    params.set('fp', fingerprint);
  }
  return `antiremote://pair?${params.toString()}`;
}
