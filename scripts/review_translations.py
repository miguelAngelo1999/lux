import json

d = json.load(open('/Users/virgoh/lux/assets/translations.json'))
langs = d['languages']
trans = d['translations']

# Key UI strings to review
samples = [
    # Tab labels
    'Proxies', 'Rules', 'Connections', 'Log', 'Settings',
    # Settings categories
    'General', 'Network', 'DNS', 'Advanced',
    # Settings tiles
    'Auto Launch', 'Auto Connect', 'Allow LAN', 'Block QUIC',
    'Find Process', 'Fake IP', 'Hijack DNS', 'Load Balancing',
    'Check for Updates', 'Reset Network', 'Backup & Restore',
    # Buttons
    'Save', 'Cancel', 'Connect', 'Disconnect', 'Add', 'Delete',
    'Import', 'Export', 'Reset', 'Install',
    # Common UI
    'No internet connection', 'Loading...', 'Error',
    'Interface Health', 'Proxy Mode', 'Local Server Port',
]

print(f"{'English':<35}", end='')
for lang in langs:
    print(f"{lang:<18}", end='')
print()
print('-' * (35 + 18 * len(langs)))

missing = []
bad = []

for s in samples:
    en = trans['en'].get(s, '—NOT EXTRACTED—')
    row = f"{s:<35}"
    for lang in langs:
        t = trans[lang].get(s, '❌ MISSING')
        if t == '❌ MISSING':
            missing.append((s, lang))
        # Flag if translation == English (likely not translated)
        elif t == s and lang not in ('en', 'fil') and len(s) > 4:
            bad.append((s, lang, t))
            t = f'⚠ {t}'
        row += f"{t:<18}"
    print(row)

print()
print(f"Total strings in JSON: {len(trans['en'])}")
print(f"Missing translations: {len(missing)}")
if missing:
    for s, lang in missing[:10]:
        print(f"  [{lang}] {s}")

print(f"Untranslated (same as English): {len(bad)}")
if bad:
    for s, lang, t in bad[:10]:
        print(f"  [{lang}] {s} = '{t}'")
