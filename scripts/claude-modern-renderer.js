'use strict';

// Claude Desktop 4.23118+ stores its renderer in app.asar/.vite/renderer/
// instead of resources/ion-dist/assets/v1. Patch the real renderer before
// app.asar is re-packed by claude-app-patch (preserves .unpacked native files).
const fs = require('fs');
const path = require('path');
const asar = require('@electron/asar');

const ANCHOR = /function ([\w$]+)\(e\)\{let t=e\.toLowerCase\(\);return [\w$]+\.test\(t\)\?!1:[\w$]+\.test\(t\)\|\|[\w$]+\.some\(\(?[\w$]+=>t\.includes\([\w$]+\)\)?\)\}/g;
const PATCHED = /function [\w$]+\(e\)\{return!0\}/g;
const NEAR = [
  'expected a gateway model route referencing an Anthropic model',
  '网关模型路由',
  '閘道模型路由',
];

function nearAnchor(source, offset) {
  const context = source.slice(Math.max(0, offset - 3000), offset + 3000);
  return NEAR.some(anchor => context.includes(anchor));
}

function rendererPath(root) {
  const dir = path.join(root, '.vite', 'renderer', 'main_window', 'assets');
  if (!fs.statSync(dir, { throwIfNoEntry: false })?.isDirectory())
    throw new Error('Modern Claude renderer not found at ' + dir);
  return dir;
}

function walkJs(dir) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...walkJs(file));
    else if (entry.isFile() && entry.name.endsWith('.js')) files.push(file);
  }
  return files;
}

function patchRenderer(root) {
  const files = walkJs(rendererPath(root));
  if (!files.length) throw new Error('Modern Claude renderer has no JS bundles');
  let hits = 0;
  for (const file of files) {
    const original = fs.readFileSync(file, 'utf8');
    const modified = original.replace(ANCHOR, (whole, name, offset) => {
      if (!nearAnchor(original, offset)) return whole;
      hits++;
      return 'function ' + name + '(e){return!0}';
    });
    if (modified !== original) fs.writeFileSync(file, modified);
  }
  // Do not produce a package that silently disables the 3P model selector
  // compatibility check when upstream changes the minified implementation.
  if (hits === 0) {
    throw new Error('Modern Claude renderer model validation anchor not found; refusing unverified patch');
  }
  console.log('PATCH_RESULT renderer-models state=patched hits=' + hits);
  return hits;
}

function verifyAsar(archive) {
  const entries = asar.listPackage(archive).map(name => name.replace(/^\/+/, ''))
    .filter(name => /^\.vite\/renderer\/main_window\/assets\/.*\.js$/.test(name));
  if (!entries.length) throw new Error('Repacked app.asar missing modern renderer JS');
  let patched = 0;
  for (const name of entries) {
    const source = asar.extractFile(archive, name).toString('utf8');
    for (const m of source.matchAll(ANCHOR)) {
      if (nearAnchor(source, m.index)) throw new Error('Unpatched renderer validation in ' + name);
    }
    for (const m of source.matchAll(PATCHED)) {
      if (nearAnchor(source, m.index)) patched++;
    }
  }
  if (patched === 0) throw new Error('Repacked app.asar missing patched renderer model validation');
  console.log('Verified modern renderer in app.asar: ' + patched + ' patched anchor(s)');
}

module.exports = { patchRenderer, verifyAsar };
