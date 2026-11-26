import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

export const MAX_JSON_BODY_BYTES = 1024 * 1024; // 1 MiB

/**
 * Constant-time token comparison to avoid timing side channels.
 */
export function constantTimeTokenEqual(expected, candidate) {
  if (typeof expected !== 'string' || typeof candidate !== 'string') {
    return false;
  }
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(candidate, 'utf8');
  if (a.length !== b.length || a.length === 0) {
    return false;
  }
  return crypto.timingSafeEqual(a, b);
}

/**
 * Extracts bearer token from Authorization header (or optional query param for WebSocket upgrades).
 */
export function extractBearerToken(req, { allowQuery = false } = {}) {
  const authHeader = req.headers?.authorization;
  if (typeof authHeader === 'string') {
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    if (match && match[1]) {
      return match[1].trim();
    }
  }
  if (allowQuery && typeof req.url === 'string') {
    try {
      const parsed = new URL(req.url, 'http://localhost');
      const token = parsed.searchParams.get('token');
      if (token) return token.trim();
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Simple in-memory fixed-window rate limiter keyed by client IP.
 */
export class RateLimiter {
  constructor({ maxAttempts = 10, windowMs = 60_000 } = {}) {
    this.maxAttempts = maxAttempts;
    this.windowMs = windowMs;
    this.buckets = new Map();
  }

  check(key) {
    const now = Date.now();
    const bucket = this.buckets.get(key);
    if (!bucket || now >= bucket.resetAt) {
      this.buckets.set(key, { count: 1, resetAt: now + this.windowMs });
      return { allowed: true, remaining: this.maxAttempts - 1 };
    }
    if (bucket.count >= this.maxAttempts) {
      return { allowed: false, retryAfterMs: Math.max(0, bucket.resetAt - now) };
    }
    bucket.count += 1;
    return { allowed: true, remaining: this.maxAttempts - bucket.count };
  }
}

/**
 * Safely resolves a relative path inside a canonical workspace root.
 * Blocks `..` traversal, NUL bytes, absolute paths, and symlink escapes.
 */
export async function resolveJailedPath(workspaceRoot, relativePath = '') {
  if (typeof relativePath !== 'string' || relativePath.includes('\0')) {
    throw new HttpError(400, 'Invalid path parameter');
  }

  const canonicalRoot = await fs.realpath(workspaceRoot);
  const cleaned = relativePath.replace(/^\/+/, '');

  if (path.isAbsolute(relativePath) && relativePath !== '' && relativePath !== '/') {
    throw new HttpError(400, 'Path must be relative to workspace root');
  }

  const candidate = path.resolve(canonicalRoot, cleaned);
  if (candidate !== canonicalRoot && !candidate.startsWith(`${canonicalRoot}${path.sep}`)) {
    throw new HttpError(403, 'Path escapes workspace boundary');
  }

  let canonicalTarget;
  try {
    canonicalTarget = await fs.realpath(candidate);
  } catch (err) {
    if (err?.code === 'ENOENT') {
      throw new HttpError(404, 'Path not found');
    }
    throw new HttpError(400, 'Cannot access requested path');
  }

  if (
    canonicalTarget !== canonicalRoot &&
    !canonicalTarget.startsWith(`${canonicalRoot}${path.sep}`)
  ) {
    throw new HttpError(403, 'Symlink escapes workspace boundary');
  }

  const rel = path.relative(canonicalRoot, canonicalTarget).split(path.sep).join('/');
  return {
    canonicalRoot,
    canonicalTarget,
    relativePath: rel,
  };
}

/**
 * Reads and parses a bounded JSON HTTP request body.
 */
export async function readJsonBody(req, maxBytes = MAX_JSON_BODY_BYTES) {
  let total = 0;
  const chunks = [];
  for await (const chunk of req) {
    total += chunk.length;
    if (total > maxBytes) {
      throw new HttpError(413, 'Request payload too large');
    }
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8').trim();
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new HttpError(400, 'Request body must be a JSON object');
    }
    return parsed;
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw new HttpError(400, 'Malformed JSON request body');
  }
}

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}
