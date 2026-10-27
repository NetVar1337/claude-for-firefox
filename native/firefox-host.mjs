import net from 'node:net';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';

const user = os.userInfo().username;
const socketPath = process.platform === 'win32'
  ? `\\\\.\\pipe\\claude-firefox-bridge-${user}`
  : path.join(os.tmpdir(), `claude-firefox-bridge-${user}.sock`);

const log = (...args) => process.stderr.write(`[Claude Firefox Host] ${args.join(' ')}\n`);
const frame = (message) => {
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
};
const frames = (onMessage) => {
  let pending = Buffer.alloc(0);
  return (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 4) {
      const length = pending.readUInt32LE(0);
      if (pending.length < 4 + length) return;
      const body = pending.subarray(4, 4 + length).toString('utf8');
      pending = pending.subarray(4 + length);
      try { onMessage(JSON.parse(body)); } catch (e) { log('invalid message', e.message); }
    }
  };
};

const toBrowser = (message) => process.stdout.write(frame(message));
const clients = new Set();

const fromBrowser = {
  ping: () => toBrowser({ type: 'pong', timestamp: Date.now() }),
  get_status: () => toBrowser({ type: 'status_response', native_host_version: 'firefox-1', computer_name: os.hostname() }),
  tool_response: ({ type, ...rest }) => { for (const c of clients) c.write(frame(rest)); },
  notification: ({ type, ...rest }) => { for (const c of clients) c.write(frame(rest)); },
};

process.stdin.on('data', frames((message) => {
  log('browser message', message.type);
  (fromBrowser[message.type] || (() => toBrowser({ type: 'error', error: `Unknown message type: ${message.type}` })))(message);
}));
process.stdin.on('end', () => process.exit(0));

if (process.platform !== 'win32') fs.rmSync(socketPath, { force: true });
const server = net.createServer((client) => {
  clients.add(client);
  log('client connected', clients.size);
  toBrowser({ type: 'mcp_connected' });
  client.on('data', frames(({ method, params }) => toBrowser({ type: 'tool_request', method, params })));
  client.on('error', () => {});
  client.on('close', () => {
    clients.delete(client);
    log('client disconnected', clients.size);
    toBrowser({ type: 'mcp_disconnected' });
  });
});
server.on('error', (e) => { log('socket error', e.message); process.exit(1); });
server.listen(socketPath, () => log('listening on', socketPath));
