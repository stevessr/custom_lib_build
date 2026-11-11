#!/usr/bin/env node
'use strict';
// Generate modern Claude Desktop shell locale and runtime translations.
// The official English map is extracted from app.asar, never synthesized.
const fs = require('fs');
const path = require('path');
const resDir = process.argv[2];
const patchDir = process.argv[3];
const lang = process.argv[4] || 'zh-CN';
if (!resDir || !patchDir || !/^zh-(CN|TW|HK)$/.test(lang))
  throw new Error('Usage: claude-modern-zh.js resources patch-directory zh-CN');

(async () => {
  const zh = require(path.join(patchDir, 'zh.js'));
  const packDir = await zh.resolveResources({
    lang, cacheDir: path.join(patchDir, '_zh-cn'),
    log: console.log,
  });
  const read = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
  const baseline = read(path.join(resDir, 'en-US.json'));
  const desktop = read(path.join(packDir, 'desktop-' + lang + '.json'));
  const frontend = read(path.join(packDir, 'frontend-' + lang + '.json'));
  const hardcoded = read(path.join(packDir, 'frontend-hardcoded-' + lang + '.json'));
  const tables = read(path.join(patchDir, 'zh-tables.json'));
  if (!baseline || !Object.keys(baseline).length || !tables.langs?.[lang])
    throw new Error('Invalid official locale baseline or translation tables');
  const merged = {};
  let translated = 0;
  for (const [key, value] of Object.entries(baseline)) {
    // Modern Claude keeps shell translations in app.asar/resources/i18n.
    const translatedValue = desktop[key] ?? frontend[key];
    if (typeof translatedValue === typeof value && translatedValue !== value) {
      merged[key] = translatedValue;
      translated++;
    } else merged[key] = value;
  }
  if (!translated) throw new Error('Modern Claude translation had zero matched keys; refusing empty locale');
  fs.writeFileSync(path.join(resDir, lang + '.json'), JSON.stringify(merged, null, 2) + '\n');
  const runtime = path.join(resDir, 'claude-zh');
  fs.mkdirSync(runtime, { recursive: true });
  const map = {};
  const valid = (a, b) => typeof a === 'string' && typeof b === 'string' &&
    a !== b && a.length <= 1000 && b.length <= 1000 &&
    !/[{\n]/.test(a) && !/[{\n]/.test(b);
  for (const [key, source] of Object.entries(baseline)) {
    const translatedValue = merged[key];
    if (valid(source, translatedValue)) map[source] = translatedValue;
  }
  for (const [key, value] of Object.entries(frontend)) {
    const source = baseline[key];
    if (valid(source, value)) map[source] = value;
  }
  for (const pair of hardcoded) {
    if (Array.isArray(pair) && valid(pair[0], pair[1])) map[pair[0]] = pair[1];
  }
  const skeleton = tables.langs[lang].dom;
  const needle = 'const L="' + lang + '",M={},';
  if (!skeleton.includes(needle)) throw new Error('Translation runtime template changed');
  fs.writeFileSync(path.join(runtime, 'dom-' + lang + '.js'),
    skeleton.replace(needle, 'const L="' + lang + '",M=' + JSON.stringify(map) + ','));
  fs.writeFileSync(path.join(runtime, 'menu-' + lang + '.json'), JSON.stringify({
    labels: tables.langs[lang].labels, roles: tables.langs[lang].roles,
  }));
  fs.writeFileSync(path.join(runtime, 'default-lang'), lang + '\n');
  fs.writeFileSync(path.join(runtime, 'installed.json'), JSON.stringify({
    lang, layout: 'app.asar/resources/i18n', translated, total: Object.keys(baseline).length,
  }, null, 2) + '\n');
  console.log('Modern Claude shell locale: ' + translated + '/' +
    Object.keys(baseline).length + ' translated keys; DOM entries ' + Object.keys(map).length);
})().catch(error => { console.error(error); process.exitCode = 1; });
