import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';

const WS_MAGIC_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_FRAME_BYTES = 2 * 1024 * 1024; // 2 MiB

/**
 * Encodes an unmasked server-to-client RFC 6455 WebSocket frame.
 */
export function encodeFrame(opcode, payloadBuffer = Buffer.alloc(0)) {
  const len = payloadBuffer.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x80 | (opcode & 0x0f);
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | (opcode & 0x0f);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | (opcode & 0x0f);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payloadBuffer]);
}

class WSClient extends EventEmitter {
  constructor(socket, id) {
    super();
    this.socket = socket;
    this.id = id;
    this.buffer = Buffer.alloc(0);
    this.closed = false;
    this.lastPongAt = Date.now();

    socket.on('data', (chunk) => this.#onData(chunk));
    socket.on('close', () => this.#markClosed());
    socket.on('error', () => this.#markClosed());
  }

  sendJSON(data) {
    if (this.closed || this.socket.destroyed) return;
    const payload = Buffer.from(JSON.stringify(data), 'utf8');
    this.socket.write(encodeFrame(0x1, payload));
  }

  ping() {
    if (this.closed || this.socket.destroyed) return;
    this.socket.write(encodeFrame(0x9, Buffer.from('ping')));
  }

  close(code = 1000, reason = '') {
    if (this.closed) return;
    this.closed = true;
    if (!this.socket.destroyed) {
      const reasonBuf = Buffer.from(reason, 'utf8');
      const payload = Buffer.alloc(2 + reasonBuf.length);
      payload.writeUInt16BE(code, 0);
      reasonBuf.copy(payload, 2);
      try {
        this.socket.end(encodeFrame(0x8, payload));
      } catch {
        this.socket.destroy();
      }
    }
    this.emit('close');
  }

  #markClosed() {
    if (this.closed) return;
    this.closed = true;
    this.emit('close');
  }

  #onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let payloadLen = second & 0x7f;
      let offset = 2;

      if (payloadLen === 126) {
        if (this.buffer.length < 4) return;
        payloadLen = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (payloadLen === 127) {
        if (this.buffer.length < 10) return;
        const bigLen = this.buffer.readBigUInt64BE(2);
        if (bigLen > BigInt(MAX_FRAME_BYTES)) {
          this.close(1009, 'Frame too large');
          return;
        }
        payloadLen = Number(bigLen);
        offset = 10;
      }

      if (payloadLen > MAX_FRAME_BYTES) {
        this.close(1009, 'Frame too large');
        return;
      }

      const maskLen = masked ? 4 : 0;
      const totalLen = offset + maskLen + payloadLen;
      if (this.buffer.length < totalLen) return;

      const maskKey = masked ? this.buffer.subarray(offset, offset + 4) : null;
      const payload = Buffer.from(this.buffer.subarray(offset + maskLen, totalLen));
      this.buffer = this.buffer.subarray(totalLen);

      if (masked && maskKey) {
        for (let i = 0; i < payload.length; i += 1) {
          payload[i] ^= maskKey[i % 4];
        }
      }

      if (opcode === 0x8) {
        this.close(1000);
        return;
      }
      if (opcode === 0x9) {
        if (!this.socket.destroyed) {
          this.socket.write(encodeFrame(0xA, payload));
        }
        continue;
      }
      if (opcode === 0xA) {
        this.lastPongAt = Date.now();
        continue;
      }
      if (opcode === 0x1) {
        this.emit('message', payload.toString('utf8'));
      }
    }
  }
}

/**
 * Lightweight zero-dependency WebSocket hub attached to an HTTP(S) server.
 */
export class WebSocketHub {
  constructor({ authenticate, onConnect, onMessage }) {
    this.authenticate = authenticate;
    this.onConnect = onConnect;
    this.onMessage = onMessage;
    this.clients = new Set();
    this.heartbeat = setInterval(() => {
      const now = Date.now();
      for (const client of this.clients) {
        if (now - client.lastPongAt > 75_000) {
          client.close(1001, 'Heartbeat timeout');
        } else {
          client.ping();
        }
      }
    }, 25_000);
    this.heartbeat.unref();
  }

  attach(httpServer, expectedPath = '/v1/stream') {
    httpServer.on('upgrade', (req, socket, head) => {
      const parsed = new URL(req.url || '/', 'http://localhost');
      if (parsed.pathname !== expectedPath) {
        socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }

      if (!this.authenticate(req)) {
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }

      const key = req.headers['sec-websocket-key'];
      if (typeof key !== 'string' || !key) {
        socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }

      const accept = crypto
        .createHash('sha1')
        .update(`${key.trim()}${WS_MAGIC_GUID}`)
        .digest('base64');

      const responseHeaders = [
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Sec-WebSocket-Accept: ${accept}`,
        '\r\n',
      ];
      socket.write(responseHeaders.join('\r\n'));

      const client = new WSClient(socket, crypto.randomUUID());
      this.clients.add(client);
      client.on('close', () => {
        this.clients.delete(client);
      });
      client.on('message', (text) => {
        if (this.onMessage) {
          this.onMessage(client, text);
        }
      });

      if (head && head.length > 0) {
        socket.emit('data', head);
      }

      if (this.onConnect) {
        this.onConnect(client);
      }
    });
  }

  broadcast(event) {
    for (const client of this.clients) {
      client.sendJSON(event);
    }
  }

  closeAll() {
    clearInterval(this.heartbeat);
    for (const client of this.clients) {
      client.close(1001, 'Server shutting down');
    }
    this.clients.clear();
  }
}
