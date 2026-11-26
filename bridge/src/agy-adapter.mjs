import { execFile, spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

/**
 * Checks whether the documented `agy` CLI binary is installed on PATH.
 */
export async function probeAgyBinary(binary = 'agy') {
  try {
    const { stdout } = await execFileAsync(binary, ['--version'], {
      timeout: 4_000,
      maxBuffer: 64 * 1024,
    });
    return { installed: true, version: stdout.trim() || 'installed', binary };
  } catch {
    return { installed: false, version: null, binary };
  }
}

/**
 * Parses one NDJSON line emitted by `agy -p ... --output-format stream-json`.
 */
export function parseStreamJsonLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const obj = JSON.parse(trimmed);
    if (typeof obj.delta === 'string') {
      return { kind: 'delta', text: obj.delta };
    }
    if (typeof obj.text === 'string' && (!obj.type || obj.type.includes('delta') || obj.type === 'message')) {
      return { kind: 'delta', text: obj.text };
    }
    if (typeof obj.content === 'string' && obj.type === 'assistant') {
      return { kind: 'delta', text: obj.content };
    }
    if (obj.type === 'tool_use' || obj.type === 'tool_call' || obj.tool) {
      return {
        kind: 'tool',
        event: {
          id: String(obj.id || crypto.randomUUID()),
          name: String(obj.name || obj.tool || 'tool'),
          status: String(obj.status || 'running'),
          summary: String(obj.summary || obj.input?.command || obj.input?.path || 'Executing tool'),
          timestamp: new Date().toISOString(),
        },
      };
    }
    if (obj.type === 'tool_result') {
      return {
        kind: 'tool',
        event: {
          id: String(obj.tool_use_id || obj.id || crypto.randomUUID()),
          name: String(obj.name || 'tool'),
          status: obj.is_error ? 'failed' : 'completed',
          summary: String(obj.summary || (obj.is_error ? 'Tool returned error' : 'Tool finished')),
          timestamp: new Date().toISOString(),
        },
      };
    }
    if (obj.type === 'error' && obj.error) {
      return { kind: 'error', message: String(obj.error?.message || obj.error) };
    }
    if (obj.type === 'result' && typeof obj.result === 'string') {
      return { kind: 'final', text: obj.result };
    }
    return null;
  } catch {
    // Plain text fallback when CLI emits non-JSON status text
    return { kind: 'delta', text: `${trimmed}\n` };
  }
}

/**
 * Real Antigravity CLI adapter wrapping documented `agy` flags.
 */
export class AgyCliAdapter {
  constructor({ binary = 'agy', allowSkipPermissions = false } = {}) {
    this.mode = 'agy';
    this.binary = binary;
    this.allowSkipPermissions = allowSkipPermissions;
  }

  async daemonCommand(action) {
    if (!['start', 'stop', 'status'].includes(action)) {
      throw new Error(`Unsupported daemon action: ${action}`);
    }
    try {
      const { stdout, stderr } = await execFileAsync(this.binary, ['remote-control', action], {
        timeout: 15_000,
        maxBuffer: 256 * 1024,
      });
      const text = `${stdout}\n${stderr}`.trim();
      const lower = text.toLowerCase();
      const running = action === 'start'
        ? true
        : action === 'stop'
          ? false
          : lower.includes('running') || lower.includes('active') || lower.includes('online');
      const urlMatch = text.match(/https?:\/\/[^\s]+/);
      return {
        state: running ? 'running' : 'stopped',
        url: urlMatch ? urlMatch[0] : null,
        detail: text || `agy remote-control ${action} succeeded`,
        updatedAt: new Date().toISOString(),
      };
    } catch (err) {
      return {
        state: 'error',
        url: null,
        detail: err?.stderr?.trim() || err?.message || `Failed to run agy remote-control ${action}`,
        updatedAt: new Date().toISOString(),
      };
    }
  }

  runPrompt({ prompt, workspacePath, signal, onDelta, onTool, onComplete, onError }) {
    const args = ['-p', prompt, '--output-format', 'stream-json'];
    if (this.allowSkipPermissions) {
      args.push('--dangerously-skip-permissions');
    }

    const child = spawn(this.binary, args, {
      cwd: workspacePath,
      shell: false,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, NO_COLOR: '1' },
    });

    let stdoutBuffer = '';
    let stderrBuffer = '';
    let accumulated = '';
    let finished = false;

    const killChild = () => {
      if (child.killed || finished) return;
      child.kill('SIGTERM');
      const killer = setTimeout(() => {
        if (!child.killed) child.kill('SIGKILL');
      }, 3_000);
      killer.unref();
    };

    if (signal) {
      if (signal.aborted) {
        killChild();
      } else {
        signal.addEventListener('abort', killChild, { once: true });
      }
    }

    child.stdout.on('data', (chunk) => {
      stdoutBuffer += chunk.toString('utf8');
      let idx = stdoutBuffer.indexOf('\n');
      while (idx !== -1) {
        const line = stdoutBuffer.slice(0, idx);
        stdoutBuffer = stdoutBuffer.slice(idx + 1);
        const parsed = parseStreamJsonLine(line);
        if (parsed?.kind === 'delta') {
          accumulated += parsed.text;
          onDelta(parsed.text);
        } else if (parsed?.kind === 'tool') {
          onTool(parsed.event);
        } else if (parsed?.kind === 'final' && !accumulated) {
          accumulated = parsed.text;
          onDelta(parsed.text);
        } else if (parsed?.kind === 'error') {
          stderrBuffer += `${parsed.message}\n`;
        }
        idx = stdoutBuffer.indexOf('\n');
      }
    });

    child.stderr.on('data', (chunk) => {
      stderrBuffer += chunk.toString('utf8');
    });

    child.on('error', (err) => {
      if (finished) return;
      finished = true;
      onError(err.message || 'Failed to spawn agy process');
    });

    child.on('close', (code) => {
      if (finished) return;
      finished = true;
      if (signal?.aborted) {
        return;
      }
      if (stdoutBuffer.trim()) {
        const parsed = parseStreamJsonLine(stdoutBuffer);
        if (parsed?.kind === 'delta') {
          accumulated += parsed.text;
          onDelta(parsed.text);
        } else if (parsed?.kind === 'final' && !accumulated) {
          accumulated = parsed.text;
          onDelta(parsed.text);
        }
      }
      if (code === 0) {
        onComplete(accumulated.trim() || '(Completed with no text output)');
      } else {
        onError(stderrBuffer.trim() || `agy exited with code ${code}`);
      }
    });
  }
}

/**
 * Simulated Antigravity adapter for environments without `agy` installed and automated E2E tests.
 */
export class MockAgyAdapter {
  constructor() {
    this.mode = 'mock';
    this.daemonState = {
      state: 'running',
      url: 'https://antigravity.local/remote-control/sim',
      detail: 'Simulated Antigravity remote-control daemon active (install `agy` on host for live CLI execution)',
      updatedAt: new Date().toISOString(),
    };
  }

  async daemonCommand(action) {
    if (!['start', 'stop', 'status'].includes(action)) {
      throw new Error(`Unsupported daemon action: ${action}`);
    }
    if (action === 'start') {
      this.daemonState = {
        state: 'running',
        url: 'https://antigravity.local/remote-control/sim',
        detail: 'Simulated remote-control daemon started',
        updatedAt: new Date().toISOString(),
      };
    } else if (action === 'stop') {
      this.daemonState = {
        state: 'stopped',
        url: null,
        detail: 'Simulated remote-control daemon stopped',
        updatedAt: new Date().toISOString(),
      };
    }
    return { ...this.daemonState };
  }

  runPrompt({ prompt, workspacePath, slashCommand, signal, onDelta, onTool, onComplete }) {
    const trimmed = (prompt || '').trim();
    const cmd = slashCommand || (trimmed.startsWith('/') ? trimmed.split(/\s+/)[0] : null);

    const toolId = crypto.randomUUID();
    const steps = buildMockResponseChunks(trimmed, cmd, workspacePath);

    let stepIndex = 0;
    let accumulated = '';
    const timers = [];

    const cleanup = () => {
      for (const t of timers) clearTimeout(t);
    };

    if (signal) {
      signal.addEventListener('abort', cleanup, { once: true });
    }

    timers.push(
      setTimeout(() => {
        if (signal?.aborted) return;
        onTool({
          id: toolId,
          name: cmd ? `slash:${cmd}` : 'workspace.inspect',
          status: 'running',
          summary: `Running on ${workspacePath}`,
          timestamp: new Date().toISOString(),
        });
      }, 40)
    );

    const emitNext = () => {
      if (signal?.aborted) return;
      if (stepIndex >= steps.length) {
        onTool({
          id: toolId,
          name: cmd ? `slash:${cmd}` : 'workspace.inspect',
          status: 'completed',
          summary: 'Finished execution cleanly',
          timestamp: new Date().toISOString(),
        });
        onComplete(accumulated);
        return;
      }
      const chunk = steps[stepIndex];
      stepIndex += 1;
      accumulated += chunk;
      onDelta(chunk);
      timers.push(setTimeout(emitNext, 45));
    };

    timers.push(setTimeout(emitNext, 90));
  }
}

function buildMockResponseChunks(prompt, cmd, workspacePath) {
  if (cmd === '/agents') {
    return [
      'Active agent pool on remote host:\n\n',
      '1. **coordinator** — idle, ready for task dispatch\n',
      '2. **code-reviewer** — standby (read-only)\n',
      '3. **test-engineer** — standby\n\n',
      `Workspace: \`${workspacePath}\``,
    ];
  }
  if (cmd === '/plan') {
    return [
      'Execution plan drafted:\n\n',
      '1. Inspect target files and git status in active workspace.\n',
      '2. Apply minimal scoped edits and keep API contracts intact.\n',
      '3. Run automated verification suite and report diff summary.\n\n',
      `Prompt received: "${prompt}"`,
    ];
  }
  if (cmd === '/compact') {
    return [
      'Context compacted for current session.\n',
      'Retained workspace path, recent decisions, and open tasks; pruned redundant tool logs.',
    ];
  }
  if (cmd === '/status') {
    return [
      `Remote bridge healthy (mock adapter).\n`,
      `Active workspace: \`${workspacePath}\`\n`,
      'Streaming transport: WebSocket `/v1/stream` connected.',
    ];
  }
  return [
    `[Remote Bridge · mock] Received: "${prompt}"\n\n`,
    `Active workspace: \`${workspacePath}\`\n`,
    'Streaming over WebSocket is live. ',
    'Install `agy` on the remote machine and start the bridge with `--adapter auto` to route turns directly to the Google Antigravity CLI.',
  ];
}

export async function createAdapter(requestedMode = 'auto', options = {}) {
  const probe = await probeAgyBinary(options.binary || 'agy');
  if (requestedMode === 'mock') {
    return { adapter: new MockAgyAdapter(), probe };
  }
  if (requestedMode === 'agy') {
    return { adapter: new AgyCliAdapter(options), probe };
  }
  if (probe.installed) {
    return { adapter: new AgyCliAdapter(options), probe };
  }
  return { adapter: new MockAgyAdapter(), probe };
}
