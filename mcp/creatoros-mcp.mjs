#!/usr/bin/env node
import { spawnSync, execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { basename, resolve, dirname } from 'node:path';
import { createInterface } from 'node:readline';

const here = fileURLToPath(import.meta.url);
const name = basename(here).replace('-mcp.mjs', '');
const bundled = resolve(dirname(here), '../../MacOS', name);
const cli = process.env.MCP_CLI || (existsSync(bundled) ? bundled : name);
const manifest = spawnSync(cli, ['mcp-manifest'], { encoding: 'utf8', timeout: 10000, maxBuffer: 4 * 1024 * 1024 });
if (manifest.status !== 0) { console.error('Cannot load CLI command table:', manifest.error?.message || manifest.stderr); process.exit(1); }
let tools, appVersion = 'development';
try { const parsed = JSON.parse(manifest.stdout); tools = parsed.tools; appVersion = parsed.version || appVersion; if (!Array.isArray(tools)) throw new Error('Missing tools'); }
catch (error) { console.error(error.message); process.exit(1); }
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const flag = key => '--' + key.replace(/[A-Z]/g, c => '-' + c.toLowerCase());
const error = (id, code, message) => send({ jsonrpc: '2.0', id, error: { code, message } });
function validArgs(tool, args) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) return false;
  const schema = tool.inputSchema;
  if ((schema.required || []).some(key => !(key in args))) return false;
  return Object.entries(args).every(([key, value]) => {
    const prop = schema.properties[key];
    if (!prop) return false;
    if (prop.type === 'array') return Array.isArray(value) && value.length <= (prop.maxItems ?? Infinity) && value.every(item => typeof item === 'string' && item.length >= 1 && new TextEncoder().encode(item).length <= (prop.items?.maxLength ?? Infinity));
    if (prop.type === 'object') return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.values(value).every(item => typeof item === 'string');
    if (prop.type === 'integer') return Number.isSafeInteger(value) && value >= (prop.minimum ?? 0) && value <= (prop.maximum ?? Number.MAX_SAFE_INTEGER);
    if (prop.type === 'string') return typeof value === 'string' && new TextEncoder().encode(value).length <= (prop.maxLength ?? Infinity) && value.length >= (prop.minLength ?? 0);
    return prop.type === 'boolean' && typeof value === 'boolean';
  });
}
createInterface({ input: process.stdin, crlfDelay: Infinity }).on('line', line => {
  let req;
  try { req = JSON.parse(line); } catch { error(null, -32700, 'Invalid JSON'); return; }
  if (!req || typeof req !== 'object' || Array.isArray(req) || req.jsonrpc !== '2.0' || typeof req.method !== 'string') { error(req?.id ?? null, -32600, 'Invalid JSON-RPC request'); return; }
  if (!('id' in req)) return; // notifications have no response
  const result = value => send({ jsonrpc: '2.0', id: req.id, result: value });
  switch (req.method) {
    case 'initialize': result({ protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name, version: appVersion } }); break;
    case 'ping': result({}); break;
    case 'tools/list': result({ tools }); break;
    case 'tools/call': {
      const tool = tools.find(t => t.name === req.params?.name);
      if (!tool || !validArgs(tool, req.params?.arguments ?? {})) { error(req.id, -32602, 'Unknown tool or invalid arguments'); break; }
      // Route by the exact CLI words the manifest carries; tool names cannot tell `set-stage` from `set stage`.
      const words = tool._meta?.creatoros?.words;
      if (!Array.isArray(words) || !words.length) { error(req.id, -32602, 'Tool has no CLI routing'); break; }
      const args = [...words, '--json'];
      for (const [key, value] of Object.entries(req.params?.arguments ?? {})) {
        if (value === false) { args.push('--no-' + flag(key).slice(2)); continue; }
        // --flag=value keeps a value that itself starts with "--" from being read as a flag.
        args.push(value === true ? flag(key) : flag(key) + '=' + (typeof value === 'object' ? JSON.stringify(value) : String(value)));
      }
      execFile(cli, args, { encoding: 'utf8', timeout: 620000, maxBuffer: 4 * 1024 * 1024 }, (failure, stdout, stderr) => {
        result({ content: [{ type: 'text', text: stdout.trim() || stderr.trim() || failure?.message || '{}' }], ...(failure ? { isError: true } : {}) });
      });
      break;
    }
    default: error(req.id, -32601, 'Unknown method');
  }
});
