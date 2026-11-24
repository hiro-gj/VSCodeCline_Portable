'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

// ポータブル Chromium は使用せず、自動ダウンロード関連環境変数も排除する
delete process.env.PLAYWRIGHT_BROWSERS_PATH;
process.env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1';

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

function isValidEdgeExecutable(candidate) {
  if (typeof candidate !== 'string' || !candidate.trim()) return false;
  const trimmed = candidate.trim().replace(/^"(.*)"$/, '$1');
  if (/[\r\n\0]/.test(trimmed)) return false;
  if (!path.isAbsolute(trimmed)) return false;
  if (path.basename(trimmed).toLowerCase() !== 'msedge.exe') return false;
  try {
    return fs.statSync(trimmed).isFile();
  } catch {
    return false;
  }
}

function getRegExePath() {
  const sysRoot = process.env.SystemRoot || process.env.WINDIR;
  if (sysRoot) {
    const full = path.join(sysRoot, 'System32', 'reg.exe');
    if (fs.existsSync(full)) return full;
  }
  return 'reg.exe';
}

function queryEdgePathFromRegistry() {
  const regExe = getRegExePath();
  const queries = [
    { key: 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\msedge.exe', args: ['/ve'], appendExe: false },
    { key: 'HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\msedge.exe', args: ['/ve'], appendExe: false },
    { key: 'HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}', args: ['/v', 'location'], appendExe: true },
    { key: 'HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}', args: ['/v', 'location'], appendExe: true },
    { key: 'HKCU\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}', args: ['/v', 'location'], appendExe: true },
  ];
  for (const q of queries) {
    try {
      const out = execFileSync(regExe, ['query', q.key, ...q.args], {
        shell: false,
        encoding: 'utf8',
        windowsHide: true,
        timeout: 5000,
      });
      for (const line of out.split(/\r?\n/)) {
        const match = line.match(/REG_(?:SZ|EXPAND_SZ)\s+(.+)$/);
        if (!match) continue;
        let val = match[1].trim();
        if (q.appendExe) val = path.join(val, 'msedge.exe');
        if (isValidEdgeExecutable(val)) return path.resolve(val);
      }
    } catch {
      // 未登録キー・アクセス不可キーはスキップして次候補へ
    }
  }
  return null;
}

function findLocalEdgeExecutable() {
  const envRoots = [
    process.env['ProgramFiles(x86)'],
    process.env.ProgramFiles,
    process.env.ProgramW6432,
    process.env.LOCALAPPDATA,
    process.env.SystemDrive ? path.join(process.env.SystemDrive + '\\', 'Program Files (x86)') : null,
    process.env.SystemDrive ? path.join(process.env.SystemDrive + '\\', 'Program Files') : null,
  ].filter(Boolean);

  for (const root of envRoots) {
    const candidate = path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe');
    if (isValidEdgeExecutable(candidate)) return path.resolve(candidate);
  }

  const fromReg = queryEdgePathFromRegistry();
  if (fromReg) return fromReg;

  throw new Error(
    'ローカルPCに Microsoft Edge (msedge.exe) が見つかりません。' +
    'Microsoft Edge をインストールするか、--executable-path で実行ファイルを指定してください。'
  );
}

if (require.main === module) {
  const extraArgs = process.argv.slice(2);
  const hasFlag = (...names) => extraArgs.some(arg => names.some(name => arg === name || arg.startsWith(name + '=')));
  const getFlagValue = name => {
    for (let i = 0; i < extraArgs.length; i++) {
      if (extraArgs[i] === name && i + 1 < extraArgs.length) return extraArgs[i + 1];
      if (extraArgs[i].startsWith(name + '=')) return extraArgs[i].slice(name.length + 1);
    }
    return undefined;
  };

  for (const [flag, directory] of [['--user-data-dir', 'user-data'], ['--output-dir', 'output']]) {
    const target = path.join(__dirname, directory);
    fs.mkdirSync(target, { recursive: true });
    if (!hasFlag(flag) && !(flag === '--user-data-dir' && hasFlag('--isolated'))) {
      process.argv.push(flag, target);
    }
  }

  const hasEndpoint = hasFlag('--cdp-endpoint', '--endpoint');
  const hasExecPath = hasFlag('--executable-path');
  const browserArg = getFlagValue('--browser');
  if (!hasEndpoint && !hasExecPath) {
    if (!browserArg) {
      const edgePath = findLocalEdgeExecutable();
      process.argv.push('--browser', 'msedge', '--executable-path', edgePath);
    } else if (browserArg === 'msedge') {
      const edgePath = findLocalEdgeExecutable();
      process.argv.push('--executable-path', edgePath);
    }
  }
  require(path.join(__dirname, 'node_modules', '@playwright', 'mcp', 'cli.js'));
}

module.exports = { findLocalEdgeExecutable, isValidEdgeExecutable };