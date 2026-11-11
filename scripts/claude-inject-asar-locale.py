#!/usr/bin/env python3
"""Inject current desktop locale and renderer patches into the pinned ASAR patcher.

Only modify the verified patchAsarFile extraction site. Do not repackage the
archive separately: upstream preserves native app.asar.unpacked modules.
"""
import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit("Usage: claude-inject-asar-locale.py linux/setup.js")

p = Path(sys.argv[1])
original = p.read_text(encoding="utf-8")
anchor = "    asar().extractAll(srcAsar, TMP);\n\n    const applied = applyPatches(TMP, patches);"
replacement = """    asar().extractAll(srcAsar, TMP);
    // Modern Claude Desktop stores its shell locale inside app.asar.
    if (process.env.CLAUDE_DESKTOP_LOCALE_SOURCE) {
        const lang = process.env.CLAUDE_DESKTOP_LOCALE_LANG || 'zh-CN';
        if (!/^zh-(CN|HK|TW)$/.test(lang)) throw new Error('Unsupported locale: ' + lang);
        const baseline = path.join(TMP, 'resources', 'i18n', 'en-US.json');
        if (!fs.existsSync(baseline)) throw new Error('Missing app.asar/resources/i18n/en-US.json');
        const data = JSON.parse(fs.readFileSync(process.env.CLAUDE_DESKTOP_LOCALE_SOURCE, 'utf8'));
        if (!data || typeof data !== 'object' || Array.isArray(data) || !Object.keys(data).length)
            throw new Error('Generated desktop translation is empty/invalid');
        const output = path.join(TMP, 'resources', 'i18n', lang + '.json');
        fs.writeFileSync(output, JSON.stringify(data));
        inf('Injected ' + lang + ' into app.asar/resources/i18n (' + Object.keys(data).length + ' keys)');
    }

    // Modern renderer JS is also inside the archive, not in ion-dist/assets/v1.
    if (process.env.CLAUDE_MODERN_RENDERER_SCRIPT) {
        require(process.env.CLAUDE_MODERN_RENDERER_SCRIPT).patchRenderer(TMP);
    }

    const applied = applyPatches(TMP, patches);"""

count = original.count(anchor)
if count != 1:
    sys.exit(f"Expected exactly one pinned patchAsarFile anchor, found {count}")
p.write_text(original.replace(anchor, replacement), encoding="utf-8")
