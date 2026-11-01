#!/usr/bin/env python3
"""Safely backport Claude Desktop's app.asar locale layout into pinned patcher.

The upstream patchAsarFile already preserves native .unpacked directories.
Inject locale into that staged tree before its existing repack rather than
repacking separately (which would lose .node libraries).
"""
import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit("Usage: claude-inject-asar-locale.py linux/setup.js")
p = Path(sys.argv[1])
original = p.read_text()
old = "    asar().extractAll(srcAsar, TMP);\n\n    const applied = applyPatches(TMP, patches);"
new = """    asar().extractAll(srcAsar, TMP);
    // Arch: newer official Claude stores desktop translations inside app.asar.
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

    const applied = applyPatches(TMP, patches);"""
count = original.count(old)
if count != 1:
    sys.exit(f"Expected exactly one pinned patchAsarFile anchor, saw {count}")
p.write_text(original.replace(old, new))
