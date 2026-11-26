import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { HttpError, resolveJailedPath } from './security.mjs';

const execFileAsync = promisify(execFile);
const MAX_FILE_PREVIEW_BYTES = 256 * 1024; // 256 KiB
const MAX_DIFF_CHARS = 128 * 1024;

const IGNORED_NAMES = new Set(['.git', 'node_modules', 'DerivedData', '.DS_Store']);

/**
 * Inspects top-level git metadata for a workspace summary card.
 */
export async function inspectWorkspaceGitSummary(workspacePath) {
  try {
    const { stdout: branchOut } = await execFileAsync(
      'git',
      ['rev-parse', '--abbrev-ref', 'HEAD'],
      { cwd: workspacePath, timeout: 3_000, maxBuffer: 16 * 1024 }
    );
    const { stdout: statusOut } = await execFileAsync(
      'git',
      ['status', '--porcelain'],
      { cwd: workspacePath, timeout: 3_000, maxBuffer: 256 * 1024 }
    );
    const dirtyLines = statusOut
      .split('\n')
      .map((l) => l.trim())
      .filter(Boolean);
    return {
      isGitRepo: true,
      branch: branchOut.trim() || 'HEAD',
      dirtyCount: dirtyLines.length,
    };
  } catch {
    return {
      isGitRepo: false,
      branch: null,
      dirtyCount: 0,
    };
  }
}

/**
 * Lists directory entries inside a jailed workspace path.
 */
export async function listWorkspaceFiles(workspacePath, relativePath = '') {
  const { canonicalTarget, relativePath: rel } = await resolveJailedPath(workspacePath, relativePath);
  const stat = await fs.stat(canonicalTarget);
  if (!stat.isDirectory()) {
    throw new HttpError(400, 'Requested path is not a directory');
  }

  const dirents = await fs.readdir(canonicalTarget, { withFileTypes: true });
  const entries = [];
  for (const d of dirents) {
    if (IGNORED_NAMES.has(d.name)) continue;
    const childAbs = path.join(canonicalTarget, d.name);
    let childStat;
    try {
      childStat = await fs.lstat(childAbs);
    } catch {
      continue;
    }
    // Skip symlinks pointing outside workspace root
    let isDirectory = d.isDirectory();
    if (childStat.isSymbolicLink()) {
      try {
        const resolved = await resolveJailedPath(
          workspacePath,
          rel ? `${rel}/${d.name}` : d.name
        );
        const targetStat = await fs.stat(resolved.canonicalTarget);
        isDirectory = targetStat.isDirectory();
        childStat = targetStat;
      } catch {
        continue;
      }
    }

    const entryRel = rel ? `${rel}/${d.name}` : d.name;
    entries.push({
      name: d.name,
      path: entryRel,
      isDirectory,
      size: isDirectory ? 0 : childStat.size,
      modifiedAt: childStat.mtime.toISOString(),
    });
  }

  entries.sort((a, b) => {
    if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  return {
    path: rel,
    entries,
  };
}

/**
 * Reads a bounded UTF-8 file preview inside a jailed workspace.
 */
export async function readWorkspaceFile(workspacePath, relativePath) {
  if (!relativePath) {
    throw new HttpError(400, 'Missing file path');
  }
  const { canonicalTarget, relativePath: rel } = await resolveJailedPath(workspacePath, relativePath);
  const stat = await fs.stat(canonicalTarget);
  if (!stat.isFile()) {
    throw new HttpError(400, 'Requested path is not a file');
  }

  const handle = await fs.open(canonicalTarget, 'r');
  try {
    const readLen = Math.min(stat.size, MAX_FILE_PREVIEW_BYTES);
    const buffer = Buffer.alloc(readLen);
    if (readLen > 0) {
      await handle.read(buffer, 0, readLen, 0);
    }

    // Simple binary check (NUL byte in first 4 KiB)
    const sample = buffer.subarray(0, Math.min(buffer.length, 4096));
    if (sample.includes(0)) {
      return {
        path: rel,
        size: stat.size,
        truncated: false,
        isBinary: true,
        content: '',
      };
    }

    return {
      path: rel,
      size: stat.size,
      truncated: stat.size > MAX_FILE_PREVIEW_BYTES,
      isBinary: false,
      content: buffer.toString('utf8'),
    };
  } finally {
    await handle.close();
  }
}

/**
 * Returns branch, changed files, and bounded unified diff for a git workspace.
 */
export async function inspectWorkspaceGitDetail(workspacePath) {
  const summary = await inspectWorkspaceGitSummary(workspacePath);
  if (!summary.isGitRepo) {
    return {
      isGitRepo: false,
      branch: null,
      changedFiles: [],
      diff: '',
    };
  }

  let statusOut = '';
  let diffOut = '';
  try {
    const res = await execFileAsync('git', ['status', '--porcelain'], {
      cwd: workspacePath,
      timeout: 4_000,
      maxBuffer: 256 * 1024,
    });
    statusOut = res.stdout;
  } catch {
    statusOut = '';
  }

  try {
    const res = await execFileAsync('git', ['diff', 'HEAD', '--no-color'], {
      cwd: workspacePath,
      timeout: 5_000,
      maxBuffer: 512 * 1024,
    });
    diffOut = res.stdout;
  } catch {
    // Fallback for repos without initial commit
    try {
      const res = await execFileAsync('git', ['diff', '--no-color'], {
        cwd: workspacePath,
        timeout: 5_000,
        maxBuffer: 512 * 1024,
      });
      diffOut = res.stdout;
    } catch {
      diffOut = '';
    }
  }

  const changedFiles = statusOut
    .split('\n')
    .filter((line) => line.length >= 4)
    .map((line) => ({
      status: line.slice(0, 2).trim() || 'M',
      path: line.slice(3).trim(),
    }));

  const truncatedDiff = diffOut.length > MAX_DIFF_CHARS
    ? `${diffOut.slice(0, MAX_DIFF_CHARS)}\n\n... [diff truncated]`
    : diffOut;

  return {
    isGitRepo: true,
    branch: summary.branch,
    changedFiles,
    diff: truncatedDiff,
  };
}
