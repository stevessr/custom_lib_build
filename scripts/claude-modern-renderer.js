'use strict';

// Claude Desktop 4.23118+ stores its renderer in app.asar/.vite/renderer/
// instead of resources/ion-dist/assets/v1. Patch the real renderer before
// app.asar is re-packed by claude-app-patch (preserves .unpacked native files).
const fs = require('fs');
const path = require('path');
// Resolve ASAR exactly as the pinned setup.js does. The renderer patch does
// not need ASAR at all; only load it during post-repack verification.
function getAsar() {
  const { createRequire } = require('module');
  const patchDir = process.env.CLAUDE_PATCH_DIR;
  if (!patchDir) throw new Error('CLAUDE_PATCH_DIR must point to the installed patch tool');
  return createRequire(path.join(patchDir, 'setup.js'))('@electron/asar');
}

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
  // The modern app may no longer ship the legacy renderer-side model
  // validator at all. Absence is not a patch failure only if every renderer
  // chunk is inspected and *none* contains the old validator's error text.
  if (hits === 0) {
    const allFiles = walkJs(path.join(root, '.vite', 'renderer'));
    const suspect = allFiles.filter(file => {
      const source = fs.readFileSync(file, 'utf8');
      return NEAR.some(anchor => source.includes(anchor));
    });
    if (suspect.length) {
      console.error('Legacy renderer validation messages still present in: ' +
        suspect.map(file => path.relative(root, file)).join(', '));
      throw new Error('Modern Claude model validator changed syntax; refusing unverified patch');
    }
    console.log('PATCH_RESULT renderer-models state=not-applicable hits=0 ' +
      'reason=no-legacy-validator-in-' + allFiles.length + '-renderer-bundles');
    return 0;
  }
  console.log('PATCH_RESULT renderer-models state=patched hits=' + hits);
  return hits;
}

function verifyAsar(archive) {
  const asar = getAsar();
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
  if (patched === 0) {
    const allRenderer = asar.listPackage(archive).map(name => name.replace(/^\/+/, ''))
      .filter(name => /^\.vite\/renderer\/.*\.js$/.test(name));
    for (const name of allRenderer) {
      const source = asar.extractFile(archive, name).toString('utf8');
      if (NEAR.some(anchor => source.includes(anchor)))
        throw new Error('Repacked ASAR contains unhandled model validator in ' + name);
    }
    console.log('Verified modern ASAR: no legacy renderer validator across ' +
      allRenderer.length + ' JS bundles');
    return;
  }
  console.log('Verified modern renderer in app.asar: ' + patched + ' patched anchor(s)');
}

if (require.main === module) {
  try {
    if (process.argv[2] !== '--verify' || !process.argv[3])
      throw new Error('Usage: claude-modern-renderer.js --verify patched/app.asar');
    verifyAsar(process.argv[3]);
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  }
}

module.exports = { patchRenderer, verifyAsar };
