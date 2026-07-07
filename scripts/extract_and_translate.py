#!/usr/bin/env python3
"""
Extract hardcoded UI strings from Lux Flutter .dart files and
translate them into multiple languages via Google Translate free API.
Output: assets/translations.json
"""

import os, re, json, time, urllib.request, urllib.parse

# ── Config ─────────────────────────────────────────────────────────────────
LIB_DIR    = os.path.join(os.path.dirname(__file__), '..', 'lib')
OUT_FILE   = os.path.join(os.path.dirname(__file__), '..', 'assets', 'translations.json')
PROXY      = 'http://127.0.0.1:1090'

TARGET_LANGS = ['fil', 'zh', 'es', 'fr', 'pt', 'ar', 'de', 'ja', 'ko']

# ── Files to scan (most UI-visible) ────────────────────────────────────────
SCAN_FILES = [
    'dashboard.dart',
    'pages/settings_page.dart',
    'pages/proxies_page.dart',
    'pages/rules_page.dart',
    'pages/connections_page.dart',
    'pages/log_page.dart',
    'widget/app_bottom_bar.dart',
    'widget/app_header_bar.dart',
    'widget/proxy_edit_dialog.dart',
    'widget/setup_wizard.dart',
    'widget/proxy_list_item.dart',
    'widget/proxy_list_card.dart',
    'widget/quick_edit_window.dart',
]

# Patterns to skip — these are never user-facing strings
SKIP_PATTERNS = [
    re.compile(r'^https?://'),
    re.compile(r'^ws://'),
    re.compile(r'^\d+$'),
    re.compile(r'^[a-z_]+$'),          # pure snake_case keys
    re.compile(r'^\$'),                 # starts with $ (interpolation)
    re.compile(r'^enc:'),
    re.compile(r'^Bearer '),
    re.compile(r'^\s*$'),
]

# Short technical terms to skip
SKIP_EXACT = {
    'en', 'zh', 'fil', 'es', 'fr', 'pt', 'ar', 'de', 'ja', 'ko',
    'http', 'https', 'DNS', 'TUN', 'SOCKS5', 'HTTP', 'HTTPS', 'MITM',
    'SSL', 'PAC', 'WPAD', 'QR', 'OK', 'CA', 'IP', 'URL', 'ID',
    'system', 'dark', 'light', 'tun', 'mixed', 'fallback', 'url-test',
    'tcp://', 'udp://', 'dhcp://', 'system://',
    'lux_core', 'lux', 'Lux',
    'Authorization', 'Bearer', 'Content-Type', 'application/json',
}

MIN_LEN = 3   # skip strings shorter than this

def should_skip(s):
    if len(s) < MIN_LEN:
        return True
    if s in SKIP_EXACT:
        return True
    for p in SKIP_PATTERNS:
        if p.search(s):
            return True
    # Skip strings with too many non-alpha chars (likely format strings or code)
    alpha = sum(c.isalpha() for c in s)
    if alpha < len(s) * 0.4:
        return True
    return False

def extract_strings_from_file(filepath):
    """Extract hardcoded English string literals from a Dart file."""
    try:
        with open(filepath, encoding='utf-8') as f:
            content = f.read()
    except FileNotFoundError:
        return []

    strings = set()

    # Patterns to find UI strings:
    patterns = [
        # Text('...') or Text("...")
        r"""Text\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # label: '...'  title: '...'  hint: '...'
        r"""(?:label|title|hint|tooltip|subtitle|hintText|labelText|message|content)\s*:\s*['"]([^'"$\n\\]{3,80})['"]""",
        # _sectionHeader('...')
        r"""_sectionHeader\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # child: const Text('...') — already caught above
        # SnackBar(content: Text('...'))
        r"""SnackBar\s*\(\s*content\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$\n\\]{3,100})['"]""",
        # AlertDialog title Text
        r"""AlertDialog[^)]*title[^:]*:\s*(?:const\s+)?(?:Row[^)]*)?Text\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # FilledButton / TextButton child: Text('...')
        r"""(?:FilledButton|TextButton|OutlinedButton|ElevatedButton)[^{]*child\s*:\s*(?:const\s+)?Text\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # notifier.show('...') — user-visible notifications
        r"""notifier\.show\s*\(\s*['"]([^'"$\n\\]{3,100})['"]""",
        # Tab labels in _tabs list
        r"""label\s*:\s*['"]([^'"$\n\\]{2,40})['"]""",
        # _switchTile('Title', ...) — first arg is the tile title
        r"""_switchTile\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # _switchTile('Title', 'Subtitle', ...) — second arg is subtitle
        r"""_switchTile\s*\(\s*['"][^'"]*['"]\s*,\s*['"]([^'"$\n\\]{3,120})['"]""",
        # Any string inside subtitle: Text('...') or subtitle: const Text('...')
        r"""subtitle\s*:\s*(?:const\s+)?(?:TText|Text)\s*\(\s*['"]([^'"$\n\\]{3,120})['"]""",
        # _dropdownTile('Title', ...) — first arg is the tile title  
        r"""_dropdownTile\s*<[^>]*>\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",        # _numberTile('Title', ...) — first arg is the tile title
        r"""_numberTile\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # _textFieldTile('Title', ...) — first arg
        r"""_textFieldTile\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # e('Title', 'searchtext', ...) — first arg in settings search index
        r"""\be\s*\(\s*['"]([^'"$\n\\]{3,80})['"]""",
        # category: 'General' etc in _SettingGroup
        r"""category\s*:\s*['"]([^'"$\n\\]{3,40})['"]""",
    ]

    for pat in patterns:
        for m in re.finditer(pat, content, re.DOTALL):
            s = m.group(1).strip()
            if not should_skip(s):
                strings.add(s)

    return sorted(strings)


def translate_batch(texts, target_lang, proxy=None):
    """Translate a list of texts to target_lang using Google Translate free API."""
    results = {}
    # Process in batches of 50
    batch_size = 50
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i+batch_size]
        # Join with newlines — Google preserves line breaks
        combined = '\n'.join(batch)
        
        params = urllib.parse.urlencode({
            'client': 'gtx',
            'sl': 'en',
            'tl': target_lang,
            'dt': 't',
            'q': combined,
        })
        url = f'https://translate.googleapis.com/translate_a/single?{params}'
        
        try:
            if proxy:
                proxy_handler = urllib.request.ProxyHandler({
                    'http': proxy, 'https': proxy
                })
                opener = urllib.request.build_opener(proxy_handler)
            else:
                opener = urllib.request.build_opener()
            
            opener.addheaders = [('User-Agent', 'Mozilla/5.0')]
            with opener.open(url, timeout=15) as resp:
                data = json.loads(resp.read().decode('utf-8'))
            
            # Parse response — data[0] is list of [translated, original] pairs
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
                    results[original] = original  # fallback to original
                    
        except Exception as e:
            print(f'  Warning: batch translate failed for {target_lang}: {e}')
            for text in batch:
                results[text] = text  # fallback
        
        time.sleep(0.3)  # be polite
    
    return results


def main():
    # ── Collect all strings ─────────────────────────────────────────────────
    all_strings = set()
    for rel_path in SCAN_FILES:
        full_path = os.path.join(LIB_DIR, rel_path)
        found = extract_strings_from_file(full_path)
        if found:
            print(f'  {rel_path}: {len(found)} strings')
        all_strings.update(found)
    
    all_strings = sorted(all_strings)
    print(f'\nTotal unique strings to translate: {len(all_strings)}')
    
    # ── Load existing translations (merge/update) ───────────────────────────
    existing = {}
    if os.path.exists(OUT_FILE):
        try:
            with open(OUT_FILE, encoding='utf-8') as f:
                existing = json.load(f)
            print(f'Loaded existing translations.json')
        except Exception:
            pass
    
    translations = existing.get('translations', {})
    
    # English baseline
    if 'en' not in translations:
        translations['en'] = {}
    for s in all_strings:
        translations['en'][s] = s
    
    # ── Translate into each target language ─────────────────────────────────
    for lang in TARGET_LANGS:
        existing_lang = translations.get(lang, {})
        # Only translate strings we don't already have
        missing = [s for s in all_strings if s not in existing_lang]
        
        if not missing:
            print(f'  {lang}: already complete ({len(existing_lang)} strings)')
            if lang not in translations:
                translations[lang] = existing_lang
            continue
        
        print(f'  {lang}: translating {len(missing)} new strings...')
        new_translations = translate_batch(missing, lang, proxy=PROXY)
        
        if lang not in translations:
            translations[lang] = {}
        translations[lang].update(existing_lang)
        translations[lang].update(new_translations)
        print(f'  {lang}: done ({len(translations[lang])} total)')
    
    # ── Write output ─────────────────────────────────────────────────────────
    output = {
        'languages': TARGET_LANGS,
        'translations': translations,
    }
    os.makedirs(os.path.dirname(OUT_FILE), exist_ok=True)
    with open(OUT_FILE, 'w', encoding='utf-8') as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    
    print(f'\nWrote {OUT_FILE}')
    print(f'Languages: {TARGET_LANGS}')
    print(f'Strings per language: {len(all_strings)}')


if __name__ == '__main__':
    main()
