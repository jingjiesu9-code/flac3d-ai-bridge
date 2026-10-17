// Minimal MCP stdio probe: spawn an MCP server, do initialize + tools/list,
// print the tool names. No SDK -- raw newline-delimited JSON-RPC.
// Usage: node mcp_stdio_probe.js <serverExe> [args...]
const { spawn } = require('child_process');

const exe = process.argv[2];
const args = process.argv.slice(3);

const child = spawn(exe, args, { stdio: ['pipe', 'pipe', 'pipe'] });

let buf = '';
const pending = new Map();
let done = false;
// Server startup chatter goes to stderr and only matters when something
// actually fails, so it is buffered and dumped on failure only.
let stderrBuf = '';

function send(obj) {
  child.stdin.write(JSON.stringify(obj) + '\n');
}

child.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    } else if (msg.method === 'notifications/message' || msg.method === 'log') {
      console.error('[server log]', JSON.stringify(msg.params));
    }
  }
});

child.stderr.on('data', (d) => { stderrBuf += d.toString('utf8'); });

function dumpStderr() {
  const t = stderrBuf.trim();
  if (t) {
    console.error('--- server stderr ---');
    console.error(t);
    console.error('---------------------');
  }
}

function request(id, method, params, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timeout on ${method}`)), timeoutMs);
    pending.set(id, (m) => { clearTimeout(t); resolve(m); });
    send({ jsonrpc: '2.0', id, method, params });
  });
}

function finish(code) {
  if (done) return;
  done = true;
  try { child.kill(); } catch {}
  setTimeout(() => process.exit(code), 200);
}

(async () => {
  try {
    const init = await request(1, 'initialize', {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: { name: 'probe', version: '1.0' },
    });
    if (init.error) throw new Error('initialize error: ' + JSON.stringify(init.error));
    const si = init.result.serverInfo || {};
    console.log(`initialize OK: ${si.name || '?'} ${si.version || '?'} (protocol ${init.result.protocolVersion})`);

    send({ jsonrpc: '2.0', method: 'notifications/initialized' });

    const list = await request(2, 'tools/list', {});
    if (list.error) throw new Error('tools/list error: ' + JSON.stringify(list.error));
    const tools = list.result.tools || [];
    console.log(`tools/list OK: ${tools.length} tools`);
    for (const t of tools) {
      console.log('  -', t.name);
    }
    finish(0);
  } catch (e) {
    console.error('PROBE FAILED:', e.message);
    dumpStderr();
    finish(1);
  }
})();

setTimeout(() => { console.error('PROBE FAILED: overall timeout'); dumpStderr(); finish(1); }, 45000);
