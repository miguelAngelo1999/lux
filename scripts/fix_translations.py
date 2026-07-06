"""
Fix known bad translations and add missing strings.
"""
import json, urllib.request, urllib.parse, time, os

OUT_FILE = '/Users/virgoh/lux/assets/translations.json'
PROXY = 'http://127.0.0.1:1090'

# ── Manual overrides for bad/wrong translations ────────────────────────────
OVERRIDES = {
    # Log → "Log" as in activity log, not "login"
    'es': {'Log': 'Registro de actividad', 'Export': 'Exportar', 'Proxies': 'Proxies'},
    'pt': {'Log': 'Registo', 'Export': 'Exportar', 'Proxies': 'Proxies'},
    'fr': {'Log': 'Journal', 'Export': 'Exporter'},
    'de': {'Log': 'Protokoll', 'Advanced': 'Erweitert'},
    'fil': {'General': 'General', 'Advanced': 'Advanced', 'Log': 'Log'},
    'zh': {'Log': '日志', 'Export': '导出'},
    'ar': {'Log': 'سجل'},
    'ja': {'Log': 'ログ'},
    'ko': {'Log': '로그'},
}

# ── Strings missing from extraction (too short or in skip list) ────────────
MISSING_STRINGS = [
    'DNS', 'Connect', 'Disconnect', 'Install', 'Error', 'Loading...',
    'TUN', 'SSL', 'MITM', 'PAC', 'Mixed', 'System', 'Direct',
    'Auto', 'Manual', 'None', 'Unknown',
    'Connected', 'Disconnected', 'Connecting...',
    'No data', 'Refresh', 'Close', 'Done', 'OK', 'Yes', 'No',
    'Upload', 'Download', 'Speed', 'Total',
    'Name', 'Server', 'Port', 'Username', 'Password',
    'Type', 'Status', 'Active', 'Inactive',
    'Rule', 'Proxy', 'Host', 'Process',
    'TUN / Mixed',
    'SSL & MITM',
    'Load Balancing',
    'Strategy', 'Interface',
]

# Strings that should NOT be translated (keep as-is)
NO_TRANSLATE = {'DNS', 'TUN', 'SSL', 'MITM', 'PAC', 'Mixed', 'OK'}

def translate_batch(texts, target_lang, proxy=None):
    to_translate = [t for t in texts if t not in NO_TRANSLATE]
    results = {t: t for t in texts if t in NO_TRANSLATE}

    batch_size = 40
    for i in range(0, len(to_translate), batch_size):
        batch = to_translate[i:i+batch_size]
        combined = '\n'.join(batch)
        params = urllib.parse.urlencode({
            'client': 'gtx', 'sl': 'en', 'tl': target_lang,
            'dt': 't', 'q': combined,
        })
        url = f'https://translate.googleapis.com/translate_a/single?{params}'
        try:
            if proxy:
                opener = urllib.request.build_opener(
                    urllib.request.ProxyHandler({'http': proxy, 'https': proxy}))
            else:
                opener = urllib.request.build_opener()
            opener.addheaders = [('User-Agent', 'Mozilla/5.0')]
            with opener.open(url, timeout=15) as resp:
                data = json.loads(resp.read().decode('utf-8'))
            translated_lines = []
            if data and data[0]:
                for item in data[0]:
                    if item and item[0]:
                        translated_lines.append(item[0])
            combined_translated = ''.join(translated_lines)
            translated_batch = combined_translated.split('\n')
            for j, original in enumerate(batch):
                if j < len(translated_batch) and translated_batch[j].strip():
                    results[original] = translated_batch[j].strip()
                else:
                    results[original] = original
        except Exception as e:
            print(f'  Warning [{target_lang}]: {e}')
            for t in batch:
                results[t] = t
        time.sleep(0.3)
    return results

# Load existing
d = json.load(open(OUT_FILE, encoding='utf-8'))
langs = d['languages']
trans = d['translations']

# Add missing strings to EN baseline
for s in MISSING_STRINGS:
    trans['en'][s] = s

# Translate missing strings for each language
for lang in langs:
    missing = [s for s in MISSING_STRINGS if s not in trans.get(lang, {})]
    if missing:
        print(f'Translating {len(missing)} missing strings for [{lang}]...')
        new = translate_batch(missing, lang, PROXY)
        if lang not in trans:
            trans[lang] = {}
        trans[lang].update(new)

# Apply manual overrides
for lang, fixes in OVERRIDES.items():
    if lang in trans:
        trans[lang].update(fixes)
        print(f'Applied {len(fixes)} overrides for [{lang}]')

# Save
d['translations'] = trans
with open(OUT_FILE, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)

print(f'\nDone. Total strings: {len(trans["en"])}')
