import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const user = os.userInfo().username;
const socketPath = process.platform === 'win32'
  ? `\\\\.\\pipe\\claude-firefox-bridge-${user}`
  : path.join(os.tmpdir(), `claude-firefox-bridge-${user}.sock`);
const CALL_TIMEOUT_MS = 120000;

const TOOLS = {
  tabs_context_mcp: 'List the tabs in the Firefox Claude tab group. Call first; pass createIfEmpty:true to create one.',
  tabs_create_mcp: 'Open a new empty tab in the Firefox Claude tab group.',
  tabs_close_mcp: 'Close a tab in the Firefox Claude tab group.',
  navigate: 'Navigate a Firefox tab to a URL ({url, tabId}).',
  computer: 'Mouse, keyboard and screenshot actions on a Firefox tab ({action, tabId, ...}).',
  read_page: 'Accessibility tree of a Firefox tab ({tabId, filter?}).',
  get_page_text: 'Plain text of a Firefox tab ({tabId}).',
  find: 'Find elements on a Firefox tab from a natural language query ({tabId, query}).',
  form_input: 'Set a form field value on a Firefox tab ({tabId, ref, value}).',
  javascript_tool: 'Run JavaScript in a Firefox tab ({tabId, action:"javascript_exec", text}).',
  read_console_messages: 'Read console messages from a Firefox tab.',
  read_network_requests: 'Read network requests from a Firefox tab.',
  resize_window: 'Resize the Firefox window.',
  file_upload: 'Upload files to a file input in a Firefox tab.',
  upload_image: 'Upload an image to a Firefox tab.',
  gif_creator: 'Record and export a GIF of Firefox browser actions.',
  browser_batch: 'Run several Firefox browser actions in one call.',
  shortcuts_list: 'List available shortcuts.',
  shortcuts_execute: 'Execute a shortcut.',
};

const callFirefox = (tool, args) => new Promise((resolve, reject) => {
  const socket = net.connect(socketPath);
  let pending = Buffer.alloc(0);
  const timer = setTimeout(() => { socket.destroy(); reject(new Error(`Firefox did not answer within ${CALL_TIMEOUT_MS / 1000}s`)); }, CALL_TIMEOUT_MS);
  socket.on('error', (e) => { clearTimeout(timer); reject(new Error(`Firefox native host not reachable (${e.code || e.message}). Start Firefox with ~/.claude/firefox/launch.bat`)); });
  socket.on('connect', () => {
    const body = Buffer.from(JSON.stringify({ method: 'execute_tool', params: { tool, args: args || {}, client_id: `firefox-mcp-${process.pid}` } }));
    const header = Buffer.alloc(4);
    header.writeUInt32LE(body.length, 0);
    setTimeout(() => socket.write(Buffer.concat([header, body])), 300);
  });
  socket.on('data', (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    if (pending.length < 4 || pending.length < 4 + pending.readUInt32LE(0)) return;
    clearTimeout(timer);
    const message = JSON.parse(pending.subarray(4, 4 + pending.readUInt32LE(0)).toString('utf8'));
    socket.destroy();
    resolve(message);
  });
});

const toMcpContent = (blocks) => (Array.isArray(blocks) ? blocks : [{ type: 'text', text: String(blocks) }]).map((block) =>
  block.type === 'image' && block.source
    ? { type: 'image', data: block.source.data, mimeType: block.source.media_type }
    : { type: 'text', text: block.text ?? JSON.stringify(block) });

const callTool = async (name, args) => {
  const reply = await callFirefox(name, args);
  if (reply.error) return { isError: true, content: toMcpContent(reply.error.content) };
  return { content: toMcpContent(reply.result?.content) };
};

const methods = {
  initialize: () => ({ protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'firefox', version: '1.0.0' } }),
  'tools/list': () => ({
    tools: Object.entries(TOOLS).map(([name, description]) => ({
      name,
      description,
      inputSchema: { type: 'object', additionalProperties: true },
    })),
  }),
  'tools/call': ({ name, arguments: args }) => {
    if (!TOOLS[name]) throw new Error(`Unknown tool: ${name}`);
    return callTool(name, args);
  },
  ping: () => ({}),
};

const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);
readline.createInterface({ input: process.stdin }).on('line', async (line) => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  if (request.id === undefined) return;
  try {
    const handler = methods[request.method];
    if (!handler) return send({ id: request.id, error: { code: -32601, message: `Method not found: ${request.method}` } });
    send({ id: request.id, result: await handler(request.params || {}) });
  } catch (e) {
    send({ id: request.id, error: { code: -32000, message: e.message } });
  }
});
