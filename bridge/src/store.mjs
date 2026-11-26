import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

export const BUILTIN_SLASH_COMMANDS = [
  {
    id: 'plan',
    command: '/plan',
    title: 'Plan Task',
    description: 'Draft a step-by-step execution plan before making changes',
    symbol: 'list.bullet.clipboard',
    category: 'workflow',
    template: '/plan ',
    autoSend: false,
  },
  {
    id: 'goal',
    command: '/goal',
    title: 'Autonomous Goal',
    description: 'Run thorough multi-step execution until the goal is verified',
    symbol: 'target',
    category: 'workflow',
    template: '/goal ',
    autoSend: false,
  },
  {
    id: 'agents',
    command: '/agents',
    title: 'Agents Panel',
    description: 'Inspect active subagents and background workers',
    symbol: 'person.3.sequence',
    category: 'control',
    template: '/agents',
    autoSend: true,
  },
  {
    id: 'compact',
    command: '/compact',
    title: 'Compact Context',
    description: 'Summarize conversation history to free context window',
    symbol: 'arrow.down.right.and.arrow.up.left',
    category: 'session',
    template: '/compact',
    autoSend: true,
  },
  {
    id: 'remote-control',
    command: '/remote-control',
    title: 'Remote Link',
    description: 'Check or toggle Antigravity remote control session link',
    symbol: 'antenna.radiowaves.left.and.right',
    category: 'control',
    template: '/remote-control',
    autoSend: true,
  },
  {
    id: 'config',
    command: '/config',
    title: 'Config Status',
    description: 'Inspect current model provider and permission rules',
    symbol: 'slider.horizontal.3',
    category: 'control',
    template: '/config',
    autoSend: true,
  },
  {
    id: 'status',
    command: '/status',
    title: 'Host Status',
    description: 'Show active workspace, branch, and remote daemon health',
    symbol: 'waveform.path.ecg',
    category: 'control',
    template: '/status',
    autoSend: true,
  },
  {
    id: 'diff',
    command: '/diff',
    title: 'Summarize Diff',
    description: 'Review uncommitted changes in the active workspace',
    symbol: 'doc.text.magnifyingglass',
    category: 'workspace',
    template: 'Summarize uncommitted git diff and flag any risks.',
    autoSend: true,
  },
  {
    id: 'test',
    command: '/test',
    title: 'Run Tests',
    description: 'Execute the project test suite and report failures',
    symbol: 'checkmark.shield',
    category: 'workspace',
    template: 'Run the test suite in the current workspace and summarize results.',
    autoSend: true,
  },
];

/**
 * In-memory + JSON persisted store for sessions, messages, and runs.
 */
export class BridgeStore {
  constructor(stateDir) {
    this.stateDir = stateDir;
    this.sessionsFile = stateDir ? path.join(stateDir, 'sessions.json') : null;
    this.sessions = new Map();
    this.runs = new Map();
    this.activeControllers = new Map();
  }

  async load(defaultWorkspaceId) {
    if (this.sessionsFile) {
      try {
        const raw = await fs.readFile(this.sessionsFile, 'utf8');
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed.sessions)) {
          for (const s of parsed.sessions) {
            if (s && s.id) {
              this.sessions.set(s.id, s);
            }
          }
        }
      } catch {
        // Start clean when no persisted file exists yet
      }
    }

    if (this.sessions.size === 0) {
      this.createSession({
        title: 'Main Control Session',
        workspaceId: defaultWorkspaceId || 'default',
      });
      await this.persist();
    }
  }

  async persist() {
    if (!this.sessionsFile) return;
    await fs.mkdir(path.dirname(this.sessionsFile), { recursive: true, mode: 0o700 });
    const payload = {
      updatedAt: new Date().toISOString(),
      sessions: Array.from(this.sessions.values()),
    };
    const tmp = `${this.sessionsFile}.tmp.${process.pid}`;
    await fs.writeFile(tmp, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
    await fs.rename(tmp, this.sessionsFile);
  }

  listSessionSummaries() {
    return Array.from(this.sessions.values())
      .map((s) => {
        const last = s.messages[s.messages.length - 1];
        const activeRun = Array.from(this.runs.values()).find(
          (r) => r.sessionId === s.id && r.status === 'running'
        );
        return {
          id: s.id,
          title: s.title,
          workspaceId: s.workspaceId,
          updatedAt: s.updatedAt,
          messageCount: s.messages.length,
          activeRunId: activeRun ? activeRun.id : null,
          lastPreview: last ? last.content.slice(0, 120) : 'No messages yet',
        };
      })
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  createSession({ title, workspaceId }) {
    const now = new Date().toISOString();
    const session = {
      id: crypto.randomUUID(),
      title: (title || '').trim() || 'New Session',
      workspaceId: workspaceId || 'default',
      createdAt: now,
      updatedAt: now,
      messages: [],
    };
    this.sessions.set(session.id, session);
    return session;
  }

  getSession(id) {
    return this.sessions.get(id) || null;
  }

  deleteSession(id) {
    // Cancel any running task on this session
    for (const run of this.runs.values()) {
      if (run.sessionId === id && run.status === 'running') {
        this.cancelRun(run.id);
      }
    }
    return this.sessions.delete(id);
  }

  appendMessage(sessionId, { role, content, slashCommand = null, status = 'completed', toolEvents = [] }) {
    const session = this.sessions.get(sessionId);
    if (!session) return null;
    const now = new Date().toISOString();
    const message = {
      id: crypto.randomUUID(),
      role,
      content,
      slashCommand,
      status,
      toolEvents,
      createdAt: now,
    };
    session.messages.push(message);
    if (session.messages.length === 1 && role === 'user' && session.title === 'New Session') {
      session.title = content.slice(0, 44).trim() || 'New Session';
    }
    session.updatedAt = now;
    return message;
  }

  registerRun({ sessionId, workspaceId, prompt, assistantMessageId }) {
    const now = new Date().toISOString();
    const controller = new AbortController();
    const run = {
      id: crypto.randomUUID(),
      sessionId,
      workspaceId,
      assistantMessageId,
      prompt,
      status: 'running',
      startedAt: now,
      finishedAt: null,
      toolEvents: [],
      error: null,
    };
    this.runs.set(run.id, run);
    this.activeControllers.set(run.id, controller);
    return { run, controller };
  }

  listRuns() {
    return Array.from(this.runs.values())
      .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
      .slice(0, 50);
  }

  activeRunsCount() {
    let count = 0;
    for (const r of this.runs.values()) {
      if (r.status === 'running') count += 1;
    }
    return count;
  }

  cancelRun(runId) {
    const run = this.runs.get(runId);
    const controller = this.activeControllers.get(runId);
    if (!run || run.status !== 'running') {
      return null;
    }
    if (controller) {
      controller.abort();
      this.activeControllers.delete(runId);
    }
    run.status = 'cancelled';
    run.finishedAt = new Date().toISOString();

    const session = this.sessions.get(run.sessionId);
    if (session) {
      const msg = session.messages.find((m) => m.id === run.assistantMessageId);
      if (msg) {
        msg.status = 'cancelled';
        if (!msg.content.trim()) {
          msg.content = '[Cancelled by Operator]';
        }
      }
      session.updatedAt = run.finishedAt;
    }
    return run;
  }

  finishRun(runId, { status, content = null, error = null }) {
    const run = this.runs.get(runId);
    if (!run || run.status !== 'running') return null;
    this.activeControllers.delete(runId);
    run.status = status;
    run.finishedAt = new Date().toISOString();
    run.error = error;

    const session = this.sessions.get(run.sessionId);
    let updatedMessage = null;
    if (session) {
      const msg = session.messages.find((m) => m.id === run.assistantMessageId);
      if (msg) {
        if (content !== null) msg.content = content;
        msg.status = status;
        updatedMessage = msg;
      }
      session.updatedAt = run.finishedAt;
    }
    return { run, message: updatedMessage };
  }
}
