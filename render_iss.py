#!/usr/bin/env python3
"""Render windows/packaging/exe/setup.iss (a flutter_distributor Jinja template)
into a concrete dist-setup.iss for ISCC. We only need the token substitutions
and the two locales (en, zh) the make_config declares."""
import re
import sys

TEMPLATE = r"windows\packaging\exe\setup.iss"
OUT = r"dist-setup.iss"
VERSION = "1.50.78"

# Values from windows/packaging/exe/make_config.yaml + Flutter build layout.
TOKENS = {
    "APP_ID": "80DF132E-434A-4DAB-9BC8-48A79C8383B9",
    "APP_VERSION": VERSION,
    "DISPLAY_NAME": "Lux",
    "PUBLISHER_NAME": "igoogolx",
    "PUBLISHER_URL": "https://github.com/leanflutter/flutter_distributor",
    "INSTALL_DIR_NAME": "{autopf}\\lux",
    "OUTPUT_BASE_FILENAME": f"Lux-{VERSION}-Windows-x64-Setup",
    "SETUP_ICON_FILE": "assets\\app_icon.ico",
    "SOURCE_DIR": "build\\windows\\x64\\runner\\Release",
    "EXECUTABLE_NAME": "lux.exe",
}
# AppId uses {{APP_ID}} inside an outer {...}; template writes AppId={{APP_ID}}
# so the rendered line must be AppId={{80DF...}} (Inno needs the double brace to
# emit a literal brace-wrapped GUID). The template already has AppId={{APP_ID}}.

# zh uses a relative ChineseSimplified.isl path that doesn't resolve when ISCC
# compiles from C:\lux-build\lux; English is the safe default installer language.
LOCALES = ["en"]


def render(text: str) -> str:
    # 1) Resolve the {% for locale in LOCALES %} ... {% endfor %} block.
    def expand_for(m):
        body = m.group(1)
        out_lines = []
        for loc in LOCALES:
            # Within the body, keep only {% if locale == 'X' %}LINE{% endif %}
            # whose X is in our locale set, emitting LINE.
            for im in re.finditer(r"\{% if locale == '([^']+)' %\}(.*?)\{% endif %\}", body):
                if im.group(1) == loc:
                    out_lines.append(im.group(2))
        return "\n".join(out_lines)

    text = re.sub(r"\{% for locale in LOCALES %\}(.*?)\{% endfor %\}",
                  expand_for, text, flags=re.DOTALL)

    # 2) Resolve the desktop-icon {% if CREATE_DESKTOP_ICON != true %} guard.
    #    make_config has create_desktop_icon: true, so the unchecked branch is
    #    dropped and the checkedonce branch kept.
    text = re.sub(
        r"\{% if CREATE_DESKTOP_ICON != true %\}unchecked\{% else %\}checkedonce\{% endif %\}",
        "checkedonce", text)

    # 3) Token substitution. AppId line needs the GUID wrapped in braces:
    #    template: AppId={{APP_ID}}  -> AppId={{80DF...}}  (Inno literal brace)
    text = text.replace("{{APP_ID}}", "{{" + TOKENS["APP_ID"] + "}")
    for k, v in TOKENS.items():
        if k == "APP_ID":
            continue
        text = text.replace("{{" + k + "}}", v)

    return text


def main():
    with open(TEMPLATE, encoding="utf-8") as f:
        tpl = f.read()
    out = render(tpl)
    # Sanity: no unresolved jinja/token left.
    leftovers = re.findall(r"\{\{[^}]+\}\}|\{%.*?%\}", out)
    # AppId's {{GUID} is intentional (single trailing brace handled above).
    leftovers = [x for x in leftovers if not x.startswith("{{" + TOKENS["APP_ID"])]
    if leftovers:
        print("UNRESOLVED:", leftovers[:10])
        sys.exit(1)
    # Replace non-ASCII arrows in Code comments that trip some ISCC encodings.
    out = out.replace("\u2192", "->")
    # The doc-comment "{ Writes ... {tmp}\luxapp_task.xml. }" contains an Inno
    # constant {tmp} whose '}' prematurely CLOSES the Pascal { } comment, which
    # makes ISCC choke on the rest of the line. Neutralise the brace in that one
    # comment (the code strings that use ExpandConstant('{tmp}') are quoted and
    # fine). Convert this specific doc comment's braces to a (* *) comment.
    out = out.replace(
        "{ Writes the LuxApp scheduled-task XML to {tmp}\\luxapp_task.xml.",
        "(* Writes the LuxApp scheduled-task XML to the tmp dir.")
    out = out.replace(
        "  - Battery/idle conditions disabled so it always runs }",
        "  - Battery/idle conditions disabled so it always runs *)")
    # ISCC 6 reads UTF-8 with BOM reliably.
    with open(OUT, "w", encoding="utf-8-sig") as f:
        f.write(out)
    print("RENDERED", OUT)


if __name__ == "__main__":
    main()
