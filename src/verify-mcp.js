'use strict';

const path = require('node:path');
const { spawn } = require('node:child_process');
process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(__dirname, 'browsers');

async function main() {
  const { chromium } = require('playwright');
  const browser = await chromium.launch({ headless: true, executablePath: chromium.executablePath() });
  try {
    const page = await browser.newPage();
    await page.goto('data:text/html,<title>Portable browser OK</title>');
    if (await page.title() !== 'Portable browser OK') throw new Error('Browser smoke test failed');
  } finally { await browser.close(); }

  const child = spawn(process.execPath, [path.join(__dirname, 'start-mcp.js'), '--headless'], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  try {
    await new Promise((resolve, reject) => {
      let buffer = '';
      const timer = setTimeout(() => reject(new Error('MCP initialize/tools/list timed out')), 30000);
      const fail = error => { clearTimeout(timer); reject(error); };
      child.on('error', fail);
      child.on('exit', code => fail(new Error(`MCP exited early: ${code}`)));
      child.stderr.on('data', data => process.stderr.write(data));
      const send = message => child.stdin.write(JSON.stringify(message) + '\n');
      child.stdout.on('data', data => {
        buffer += data.toString();
        let newline;
        while ((newline = buffer.indexOf('\n')) !== -1) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          let message;
          try { message = JSON.parse(line); } catch { return fail(new Error(`Invalid MCP output: ${line}`)); }
          if (message.error) return fail(new Error(JSON.stringify(message.error)));
          if (message.id === 1) {
            send({ jsonrpc: '2.0', method: 'notifications/initialized' });
            send({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} });
          }
          if (message.id === 2) {
            if (!message.result.tools.some(tool => tool.name === 'browser_navigate')) return fail(new Error('Missing browser tools'));
            clearTimeout(timer);
            resolve();
          }
        }
      });
      send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'portable-smoke-test', version: '1.0.0' },
      } });
    });
  } finally { child.kill(); }
  console.log('[PASS] Portable Chromium launch and MCP initialize/tools/list');
}
main().catch(error => { console.error(error); process.exitCode = 1; });