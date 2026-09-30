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
let tools;
try { tools = JSON.parse(manifest.stdout).tools; if (!Array.isArray(tools)) throw new Error('Missing tools'); }
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
    case 'initialize': result({ protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name, version: '1.3.0' } }); break;
    case 'ping': result({}); break;
    case 'tools/list': result({ tools }); break;
    case 'tools/call': {
      const tool = tools.find(t => t.name === req.params?.name);
      if (!tool || !validArgs(tool, req.params?.arguments ?? {})) { error(req.id, -32602, 'Unknown tool or invalid arguments'); break; }
      const args = [...tool.name.split('_'), '--json'];
      for (const [key, value] of Object.entries(req.params?.arguments ?? {})) {
        if (value === false) continue;
        args.push(flag(key));
        if (value !== true) args.push(String(value));
      }
      execFile(cli, args, { encoding: 'utf8', timeout: 620000, maxBuffer: 4 * 1024 * 1024 }, (failure, stdout, stderr) => {
        result({ content: [{ type: 'text', text: stdout.trim() || stderr.trim() || failure?.message || '{}' }], ...(failure ? { isError: true } : {}) });
      });
      break;
    }
    default: error(req.id, -32601, 'Unknown method');
  }
});
