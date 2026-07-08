#!/bin/bash
set -e
sudo pkill -9 -x lux_core_real 2>/dev/null || true
pkill -9 -x Lux 2>/dev/null || true
sleep 2
sudo rm -rf /Applications/Lux.app
sudo cp -R /Users/virgoh/lux/build/macos/Build/Products/Release/Lux.app /Applications/Lux.app
BIN="/Applications/Lux.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL="${BIN}_real"
sudo mv "$BIN" "$REAL"
printf '#!/bin/bash\nexec sudo "%s" "$@"\n' "$REAL" | sudo tee "$BIN" > /dev/null
sudo chmod 755 "$BIN"
sudo chown root:wheel "$REAL"
sudo chmod 770 "$REAL"
sudo chmod u+s "$REAL"
USER_=$(whoami)
printf '%s ALL=(root) NOPASSWD: %s *\n%s ALL=(root) NOPASSWD: /bin/bash /tmp/lux_proxy_apply.sh\n%s ALL=(root) NOPASSWD: /bin/bash /tmp/lux_proxy_clear.sh\n%s ALL=(root) NOPASSWD: /bin/bash /tmp/lux_cert_install.sh\n' \
  "$USER_" "$REAL" "$USER_" "$USER_" "$USER_" | sudo tee /etc/sudoers.d/lux_core > /dev/null
sudo chmod 0440 /etc/sudoers.d/lux_core
sudo visudo -c -f /etc/sudoers.d/lux_core
echo "Deployed"
open /Applications/Lux.app
