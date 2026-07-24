#!/bin/bash
# lux_proxy_apply.sh <proxy_addr> <no_proxy>
# e.g. lux_proxy_apply.sh 127.0.0.1:1090 "localhost,127.0.0.1,*.local"
# Static script — owned by root:wheel, not writable by user.
# Proxy address passed as argument, never embedded in the file.
set -euo pipefail

PROXY_ADDR="${1:-}"
NO_PROXY_VAL="${2:-localhost,127.0.0.1,10.255.0.1,*.local,169.254/16}"

if [ -z "$PROXY_ADDR" ]; then
  echo "Usage: lux_proxy_apply.sh <host:port> [no_proxy]" >&2
  exit 1
fi

PROXY="http://$PROXY_ADDR"

launchctl setenv HTTP_PROXY  "$PROXY"         2>/dev/null || true
launchctl setenv HTTPS_PROXY "$PROXY"         2>/dev/null || true
launchctl setenv http_proxy  "$PROXY"         2>/dev/null || true
launchctl setenv https_proxy "$PROXY"         2>/dev/null || true
launchctl setenv NO_PROXY    "$NO_PROXY_VAL"  2>/dev/null || true
launchctl setenv no_proxy    "$NO_PROXY_VAL"  2>/dev/null || true
launchctl setenv NODE_EXTRA_CA_CERTS /etc/ssl/cert.pem 2>/dev/null || true
launchctl setenv CURL_CA_BUNDLE      /etc/ssl/cert.pem 2>/dev/null || true

# Set proxy bypass domains for all active network services
while IFS= read -r SVC; do
  networksetup -setproxybypassdomains "$SVC" \
    localhost 127.0.0.1 10.255.0.1 "*.local" "169.254/16" 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

# Persist across reboots via /etc/launchd.conf
LAUNCHD=/etc/launchd.conf
touch "$LAUNCHD" 2>/dev/null || true
grep -v "LUX_PROXY" "$LAUNCHD" > /tmp/lux_launchd_clean.conf 2>/dev/null || true
printf "setenv HTTP_PROXY %s # LUX_PROXY\n"   "$PROXY"         >> /tmp/lux_launchd_clean.conf
printf "setenv HTTPS_PROXY %s # LUX_PROXY\n"  "$PROXY"         >> /tmp/lux_launchd_clean.conf
printf "setenv http_proxy %s # LUX_PROXY\n"   "$PROXY"         >> /tmp/lux_launchd_clean.conf
printf "setenv https_proxy %s # LUX_PROXY\n"  "$PROXY"         >> /tmp/lux_launchd_clean.conf
printf "setenv NO_PROXY %s # LUX_PROXY\n"     "$NO_PROXY_VAL"  >> /tmp/lux_launchd_clean.conf
printf "setenv no_proxy %s # LUX_PROXY\n"     "$NO_PROXY_VAL"  >> /tmp/lux_launchd_clean.conf
cp /tmp/lux_launchd_clean.conf "$LAUNCHD" 2>/dev/null || true

# Persist via /etc/zshenv for new terminal sessions
touch /etc/zshenv 2>/dev/null || true
grep -v "LUX_PROXY" /etc/zshenv > /tmp/lux_zshenv_clean 2>/dev/null || true
printf 'export HTTP_PROXY="%s"  # LUX_PROXY\n'  "$PROXY"         >> /tmp/lux_zshenv_clean
printf 'export HTTPS_PROXY="%s" # LUX_PROXY\n'  "$PROXY"         >> /tmp/lux_zshenv_clean
printf 'export http_proxy="%s"  # LUX_PROXY\n'  "$PROXY"         >> /tmp/lux_zshenv_clean
printf 'export https_proxy="%s" # LUX_PROXY\n'  "$PROXY"         >> /tmp/lux_zshenv_clean
printf 'export NO_PROXY="%s"    # LUX_PROXY\n'  "$NO_PROXY_VAL"  >> /tmp/lux_zshenv_clean
printf 'export no_proxy="%s"    # LUX_PROXY\n'  "$NO_PROXY_VAL"  >> /tmp/lux_zshenv_clean
printf 'export CURL_CA_BUNDLE=/etc/ssl/cert.pem # LUX_PROXY\n'   >> /tmp/lux_zshenv_clean
printf 'export NODE_EXTRA_CA_CERTS=/etc/ssl/cert.pem # LUX_PROXY\n' >> /tmp/lux_zshenv_clean
cp /tmp/lux_zshenv_clean /etc/zshenv 2>/dev/null || true

echo "LUX_PROXY_APPLY_OK"
