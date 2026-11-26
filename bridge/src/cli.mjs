#!/usr/bin/env node
import os from 'node:os';
import path from 'node:path';
import { renderTerminalQR } from './qrcode.mjs';
import { createBridgeServer } from './server.mjs';

function parseArgs(argv) {
  const opts = {
    host: process.env.ANTIREMOTE_HOST || '0.0.0.0',
    port: Number(process.env.ANTIREMOTE_PORT || 8787),
    workspaces: [],
    adapter: process.env.ANTIREMOTE_ADAPTER || 'auto',
    token: process.env.ANTIREMOTE_TOKEN || undefined,
    hostName: process.env.ANTIREMOTE_NAME || os.hostname(),
    tlsCertPath: process.env.ANTIREMOTE_TLS_CERT || undefined,
    tlsKeyPath: process.env.ANTIREMOTE_TLS_KEY || undefined,
    stateDir: process.env.ANTIREMOTE_STATE_DIR || path.join(os.homedir(), '.antiremote-bridge'),
    allowSkipPermissions: false,
    printQR: true,
    help: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === '-h' || arg === '--help') opts.help = true;
    else if (arg === '--host' && next) { opts.host = next; i += 1; }
    else if (arg === '--port' && next) { opts.port = Number(next); i += 1; }
    else if (arg === '--workspace' && next) { opts.workspaces.push(next); i += 1; }
    else if (arg === '--adapter' && next) { opts.adapter = next; i += 1; }
    else if (arg === '--token' && next) { opts.token = next; i += 1; }
    else if (arg === '--name' && next) { opts.hostName = next; i += 1; }
    else if (arg === '--tls-cert' && next) { opts.tlsCertPath = next; i += 1; }
    else if (arg === '--tls-key' && next) { opts.tlsKeyPath = next; i += 1; }
    else if (arg === '--state-dir' && next) { opts.stateDir = next; i += 1; }
    else if (arg === '--allow-skip-permissions') { opts.allowSkipPermissions = true; }
    else if (arg === '--no-qr') { opts.printQR = false; }
  }

  if (opts.workspaces.length === 0) {
    opts.workspaces.push(process.cwd());
  }
  return opts;
}

function printHelp() {
  process.stdout.write(`AntiRemote Bridge — Self-hosted remote control daemon for Google Antigravity CLI (agy)

Usage:
  antiremote-bridge [options]

Options:
  --host <addr>               Bind address (default: 0.0.0.0)
  --port <num>                Listen port (default: 8787)
  --workspace <dir>           Trusted workspace directory (repeatable; default: cwd)
  --adapter <auto|agy|mock>   CLI execution adapter (default: auto)
  --name <label>              Display name shown on iPhone (default: hostname)
  --token <secret>            Explicit bearer token (default: auto-generated in state-dir)
  --tls-cert <file>           TLS certificate PEM file (enables HTTPS/WSS)
  --tls-key <file>            TLS private key PEM file
  --state-dir <dir>           Persistent state directory (default: ~/.antiremote-bridge)
  --allow-skip-permissions    Pass --dangerously-skip-permissions to agy headless runs
  --no-qr                     Skip ASCII QR code output on startup
  -h, --help                  Show help
`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    printHelp();
    process.exit(0);
  }

  const bridge = await createBridgeServer(opts);
  const info = await bridge.start();

  process.stdout.write(`\nAntiRemote Bridge listening on ${info.baseUrl}\n`);
  process.stdout.write(`Adapter:     ${info.adapterMode} (agy installed: ${info.agyInstalled ? 'yes' : 'no'})\n`);
  process.stdout.write(`Workspaces:  ${bridge.workspaces.map((w) => w.path).join(', ')}\n`);
  process.stdout.write(`Pair Code:   ${info.pairingCode} (single-use, expires ${info.pairingExpiresAt})\n`);
  process.stdout.write(`Pair URI:    ${info.pairingURI}\n`);
  if (info.tlsFingerprint) {
    process.stdout.write(`TLS SHA-256: ${info.tlsFingerprint}\n`);
  }

  if (opts.printQR) {
    process.stdout.write(`\nScan this QR code in AntiRemote iOS (Settings -> Pair via QR):\n\n`);
    process.stdout.write(`${renderTerminalQR(info.pairingURI)}\n\n`);
  }

  const shutdown = async () => {
    process.stdout.write('\nShutting down AntiRemote Bridge...\n');
    await bridge.stop();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((err) => {
  process.stderr.write(`Fatal error: ${err?.message || err}\n`);
  process.exit(1);
});
