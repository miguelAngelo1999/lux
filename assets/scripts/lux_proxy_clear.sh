#!/bin/bash
# lux_proxy_clear.sh
# Static script — owned by root:wheel, not writable by user.
set -euo pipefail

for VAR in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy \
           NO_PROXY no_proxy NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE; do
  launchctl unsetenv "$VAR" 2>/dev/null || true
done

grep -v "LUX_PROXY" /etc/launchd.conf > /tmp/lux_launchd_clean.conf 2>/dev/null || true
cp /tmp/lux_launchd_clean.conf /etc/launchd.conf 2>/dev/null || true

grep -v "LUX_PROXY" /etc/zshenv > /tmp/lux_zshenv_clean 2>/dev/null || true
cp /tmp/lux_zshenv_clean /etc/zshenv 2>/dev/null || true

echo "LUX_PROXY_CLEAR_OK"
