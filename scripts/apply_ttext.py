#!/usr/bin/env python3
"""
Apply TText to key Lux Flutter UI files.
Replaces Text('hardcoded') with TText('hardcoded') where appropriate.
"""
import re, os

LIB = '/Users/virgoh/lux/lib'
IMPORT = "import 'package:lux/util/t_text.dart';\n"

def add_import(content, import_line):
    if 't_text.dart' in content:
        return content
    # Insert after last import line
    lines = content.split('\n')
    last_import = 0
    for i, line in enumerate(lines):
        if line.startswith('import '):
            last_import = i
    lines.insert(last_import + 1, import_line.strip())
    return '\n'.join(lines)

def replace_text_with_ttext(content):
    """Replace Text('literal') and Text("literal") with TText(...)
    Handles both bare Text('x') and Text('x', style: ...) forms.
    Only replaces plain string literals — skips interpolation and variables."""

    # Replace: Text('literal string', ...) — single quotes with optional trailing args
    content = re.sub(
        r'\bText\(\'([^\'$\n\\{}()]{2,120})\'\)',
        lambda m: f"TText('{m.group(1)}')",
        content
    )
    content = re.sub(
        r'\bText\(\'([^\'$\n\\{}()]{2,120})\',',
        lambda m: f"TText('{m.group(1)}',",
        content
    )
    # Replace: Text("literal string", ...) — double quotes with optional trailing args
    content = re.sub(
        r'\bText\("([^"$\n\\{}()]{2,120})"\)',
        lambda m: f'TText("{m.group(1)}")',
        content
    )
    content = re.sub(
        r'\bText\("([^"$\n\\{}()]{2,120})",',
        lambda m: f'TText("{m.group(1)}",',
        content
    )
    # Replace: const Text('literal') -> TText('literal')  (TText is not const)
    content = re.sub(
        r'\bconst\s+TText\(',
        'TText(',
        content
    )
    return content

def process_file(path):
    with open(path, encoding='utf-8') as f:
        original = f.read()
    
    content = replace_text_with_ttext(original)
    
    if content != original:
        content = add_import(content, IMPORT)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        changes = original.count("Text('") + original.count('Text("') - content.count("Text('") - content.count('Text("')
        # Count TText additions instead
        added = content.count('TText(') - original.count('TText(')
        print(f'  {os.path.relpath(path, LIB)}: +{added} TText replacements')
        return True
    return False

TARGET_FILES = [
    'dashboard.dart',
    'pages/settings_page.dart',
    'pages/proxies_page.dart',
    'pages/rules_page.dart',
    'pages/connections_page.dart',
    'pages/log_page.dart',
    'widget/app_header_bar.dart',
    'widget/app_bottom_bar.dart',
    'widget/proxy_edit_dialog.dart',
    'widget/proxy_list_item.dart',
    'widget/proxy_list_card.dart',
    'widget/quick_edit_window.dart',
    'widget/setup_wizard.dart',
]

changed = 0
for rel in TARGET_FILES:
    full = os.path.join(LIB, rel)
    if os.path.exists(full):
        if process_file(full):
            changed += 1
    else:
        print(f'  SKIP (not found): {rel}')

print(f'\nDone. {changed} files updated.')
