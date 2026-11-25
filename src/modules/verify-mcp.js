'use strict';

const path = require('node:path');
const { spawn } = require('node:child_process');
const { findLocalEdgeExecutable, ensurePortableBrowserEnvironment } = require('./start-mcp.js');

ensurePortableBrowserEnvironment();

const LAUNCH_TIMEOUT_MS = 30000;

async function launchEdgeForSmokeTest(chromium, edgePath) {
  const forceNoSandbox = process.env.PORTABLE_PLAYWRIGHT_NO_SANDBOX === '1';
  if (!forceNoSandbox) {
    try {
      return await chromium.launch({
        channel: 'msedge',
        executablePath: edgePath,
        headless: true,
        chromiumSandbox: true,
        timeout: LAUNCH_TIMEOUT_MS,
      });
    } catch (error) {
      // タイムアウト時は二重待機を避けてそのまま送出し、サンドボックス制限時のみフォールバック
      if (error && error.name === 'TimeoutError') throw error;
    }
  }
  return await chromium.launch({
    channel: 'msedge',
    executablePath: edgePath,
    headless: true,
    chromiumSandbox: false,
    timeout: LAUNCH_TIMEOUT_MS,
  });
}

async function terminateChildProcess(child) {
  if (!child || child.exitCode !== null || child.killed) return;
  await new Promise(resolve => {
    const timer = setTimeout(resolve, 3000);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
    try { child.kill(); } catch { clearTimeout(timer); resolve(); }
  });
}

async function main() {
  const edgePath = findLocalEdgeExecutable();
  const { chromium } = require('playwright');
  const browser = await launchEdgeForSmokeTest(chromium, edgePath);
  try {
    const page = await browser.newPage();
    await page.goto('data:text/html,<title>Portable browser OK</title>');
    if (await page.title() !== 'Portable browser OK') throw new Error('Browser smoke test failed');
  } finally {
    await browser.close();
  }

  const childEnv = { ...process.env, ELECTRON_RUN_AS_NODE: '1', PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD: '1' };
  delete childEnv.PLAYWRIGHT_BROWSERS_PATH;

  const child = spawn(process.execPath, [path.join(__dirname, 'start-mcp.js'), '--headless'], {
    env: childEnv, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  try {
    await new Promise((resolve, reject) => {
      let buffer = '';
      let settled = false;
      const timer = setTimeout(() => fail(new Error('MCP initialize/tools/list timed out')), 30000);
      const fail = error => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(error);
      };
      const succeed = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      child.on('error', fail);
      child.on('exit', code => { if (!settled) fail(new Error(`MCP exited early: ${code}`)); });
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
            return succeed();
          }
        }
      });
      send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'portable-smoke-test', version: '1.0.0' },
      } });
    });
  } finally {
    await terminateChildProcess(child);
  }
  console.log('[PASS] Local Microsoft Edge launch and MCP initialize/tools/list');
}
main().catch(error => { console.error(error); process.exitCode = 1; });