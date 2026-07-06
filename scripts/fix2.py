import json

OUT = '/Users/virgoh/lux/assets/translations.json'
d = json.load(open(OUT, encoding='utf-8'))
t = d['translations']

fixes = {
    'es': {
        'General': 'General',
        'Import': 'Importar',
        'Export': 'Exportar',
        'Proxies': 'Proxies',
        'No internet connection': 'Sin conexión a internet',
    },
    'pt': {
        'General': 'Geral',
        'Import': 'Importar',
        'Export': 'Exportar',
        'Proxies': 'Proxies',
        'No internet connection': 'Sem conexão à internet',
    },
    'fr': {
        'General': 'Général',
        'Import': 'Importer',
        'No internet connection': 'Pas de connexion internet',
    },
    'de': {
        'General': 'Allgemein',
        'Import': 'Importieren',
        'No internet connection': 'Keine Internetverbindung',
    },
    'zh': {
        'General': '通用',
        'Import': '导入',
        'Export': '导出',
        'No internet connection': '无网络连接',
        'Interface Health': '接口健康',
    },
    'ja': {
        'General': '一般',
        'Import': 'インポート',
        'Export': 'エクスポート',
        'No internet connection': 'インターネット接続なし',
        'Interface Health': 'インターフェースの健全性',
    },
    'ko': {
        'General': '일반',
        'Import': '가져오기',
        'Export': '내보내기',
        'No internet connection': '인터넷 연결 없음',
    },
    'ar': {
        'General': 'عام',
        'Import': 'استيراد',
        'Export': 'تصدير',
        'No internet connection': 'لا يوجد اتصال بالإنترنت',
    },
    'fil': {
        'General': 'General',
        'Import': 'Mag-import',
        'Export': 'I-export',
        'No internet connection': 'Walang koneksyon sa internet',
        'Interface Health': 'Kalusugan ng Interface',
    },
}

for lang, f in fixes.items():
    if lang not in t:
        t[lang] = {}
    t[lang].update(f)
    print(f'[{lang}] applied {len(f)} fixes')

d['translations'] = t
with open(OUT, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print(f'Done. {len(t["en"])} total strings.')
