'use strict';

const fs = require('node:fs');
const path = require('node:path');

// All runtime paths follow this file, even after moving to another drive.
process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(__dirname, 'browsers');
const { chromium } = require('playwright');
const extraArgs = process.argv.slice(2);
const hasFlag = (...names) => extraArgs.some(arg => names.some(name => arg === name || arg.startsWith(name + '=')));
for (const [flag, directory] of [['--user-data-dir', 'user-data'], ['--output-dir', 'output']]) {
  const target = path.join(__dirname, directory);
  fs.mkdirSync(target, { recursive: true });
  if (!hasFlag(flag) && !(flag === '--user-data-dir' && hasFlag('--isolated'))) {
    process.argv.push(flag, target);
  }
}
if (!hasFlag('--browser', '--executable-path', '--cdp-endpoint', '--endpoint')) {
  process.argv.push('--executable-path', chromium.executablePath());
}
require(path.join(__dirname, 'node_modules', '@playwright', 'mcp', 'cli.js'));