import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { resolve, join, dirname } from 'node:path';

// Scope is an explicit publication allowlist, never the user's home or scan history.
const root = resolve(import.meta.dirname);
const files = ['README.md', 'VERIFICATION.md', 'CHANGELOG.md', 'LICENSE', 'Package.swift', 'Info.plist', '.gitignore', 'build-app.sh', 'package-release.sh', 'verify-publication.mjs'];
function walk(directory) {
  for (const name of readdirSync(join(root, directory))) {
    const path = join(directory, name);
    if (statSync(join(root, path)).isDirectory()) walk(path);
    else files.push(path);
  }
}
walk('Sources'); walk('docs');
const issues = [];
function safeResolutionExif(data) {
  // AppKit adds a TIFF containing only DPI, resolution units and pixel dimensions.
  if (data.toString('ascii', 0, 2) !== 'MM' || data.readUInt16BE(2) !== 42) return false;
  const allowed = new Set([0x011a, 0x011b, 0x0128, 0x8769, 0xa002, 0xa003]);
  function ifd(offset, depth = 0) {
    if (depth > 2 || offset + 2 > data.length) return false;
    const count = data.readUInt16BE(offset);
    if (offset + 2 + count * 12 + 4 > data.length) return false;
    for (let n = 0; n < count; n++) {
      const pos = offset + 2 + n * 12;
      const tag = data.readUInt16BE(pos), type = data.readUInt16BE(pos + 2), amount = data.readUInt32BE(pos + 4), value = data.readUInt32BE(pos + 8);
      if (!allowed.has(tag) || amount !== 1 || ![3, 4, 5].includes(type)) return false;
      if (tag === 0x8769 && !ifd(value, depth + 1)) return false;
      if (type === 5 && value + 8 > data.length) return false;
    }
    return data.readUInt32BE(offset + 2 + count * 12) === 0;
  }
  return ifd(data.readUInt32BE(4));
}
const sensitive = [
  /\/Users\/(?!demo(?:\/|\b)|build(?:\/|\b))[A-Za-z0-9._-]+\//,
  /\/var\/folders\/[A-Za-z0-9]{2}\//,
  /(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{30,})/,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
];
for (const relative of files) {
  const data = readFileSync(join(root, relative));
  const text = data.toString('utf8');
  if (sensitive.some(pattern => pattern.test(text))) issues.push(`Sensitive pattern: ${relative}`);
  if (relative.endsWith('.md')) {
    for (const match of text.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
      const target = match[1].replace(/^<|>$/g, '').split('#')[0];
      if (!target || /^(?:https?:|mailto:)/.test(target)) continue;
      if (target.startsWith('/') || !existsSync(resolve(dirname(join(root, relative)), target))) issues.push(`Broken or absolute local link: ${relative} -> ${target}`);
    }
  }
  if (relative.endsWith('.png')) {
    if (data.readUInt32BE(0) !== 0x89504e47) issues.push(`Not PNG: ${relative}`);
    let offset = 8;
    while (offset + 12 <= data.length) {
      const size = data.readUInt32BE(offset);
      const type = data.toString('ascii', offset + 4, offset + 8);
      if (['tEXt', 'zTXt', 'iTXt'].includes(type) || type === 'eXIf' && !safeResolutionExif(data.subarray(offset + 8, offset + 8 + size))) issues.push(`Unexpected image metadata ${type}: ${relative}`);
      offset += size + 12;
    }
  }
}
for (const name of ['overview', 'space', 'rules', 'protected', 'apps', 'preview', 'recovery', 'settings']) {
  if (!existsSync(join(root, 'docs/images', name + '.png'))) issues.push(`Missing public image: ${name}`);
}
const binary = join(root, 'MacClean.app/Contents/MacOS/MacClean');
if (!existsSync(binary)) issues.push('Missing release executable');
else if (sensitive.some(pattern => pattern.test(readFileSync(binary).toString('utf8')))) issues.push('Sensitive pattern in release executable');
if (issues.length) { console.error(issues.join('\n')); process.exit(1); }
console.log(`PUBLICATION CHECK PASSED: ${files.length} allowlisted files, 8 PNGs, executable, local Markdown links`);
