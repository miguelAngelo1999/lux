#!/usr/bin/env python3
"""
Fix: move r.Mount("/ssl-inspect", ...) inside the authenticated r.Group.
"""
import os, re

ROUTES = os.path.expanduser('~/itun2socks/api/routes/routes.go')

with open(ROUTES) as f:
    content = f.read()

# Remove the out-of-group mount (handles any whitespace/newline variations)
content_fixed = re.sub(
    r'\s*r\.Mount\("/ssl-inspect",\s*sslInspectRouter\(\)\)',
    '',
    content
)

# Insert it inside the group, just before r.Mount("/auth", authRouter())
old = 'r.Mount("/auth", authRouter())'
new = 'r.Mount("/ssl-inspect", sslInspectRouter())\n\t\t\tr.Mount("/auth", authRouter())'

if old not in content_fixed:
    print("ERROR: could not find auth mount anchor")
    exit(1)

content_fixed = content_fixed.replace(old, new, 1)

with open(ROUTES, 'w') as f:
    f.write(content_fixed)

print("Fixed: /ssl-inspect is now inside the authenticated group")
