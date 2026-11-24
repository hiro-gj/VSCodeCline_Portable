'use strict';

const fs = require('node:fs');
const path = require('node:path');

// All runtime paths follow this file, even after moving to another drive.
process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(__dirname, 'browsers');

const clineDirCandidate = path.resolve(__dirname, '..', '..');
const homeCandidate = path.resolve(clineDirCandidate, '..');
const dataCandidate = path.resolve(homeCandidate, '..');
if (path.basename(clineDirCandidate).toLowerCase() === '.cline' &&
    path.basename(homeCandidate).toLowerCase() === 'home' &&
    fs.existsSync(dataCandidate)) {
  const tmpCandidate = path.join(dataCandidate, 'tmp');
  fs.mkdirSync(tmpCandidate, { recursive: true });
  const dataPrefix = (path.resolve(dataCandidate).replace(/[\\/]+$/, '') + path.sep).toLowerCase();
  const isInsidePortableData = value =>
    typeof value === 'string' && value.length > 0 &&
    path.resolve(value).toLowerCase().startsWith(dataPrefix);
  if (!isInsidePortableData(process.env.USERPROFILE)) process.env.USERPROFILE = homeCandidate;
  if (!isInsidePortableData(process.env.HOME)) process.env.HOME = homeCandidate;
  if (!isInsidePortableData(process.env.TEMP)) process.env.TEMP = tmpCandidate;
  if (!isInsidePortableData(process.env.TMP)) process.env.TMP = tmpCandidate;
  if (!isInsidePortableData(process.env.TMPDIR)) process.env.TMPDIR = tmpCandidate;
}

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