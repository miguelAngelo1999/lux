#!/bin/bash
# ============================================================
# Lux Installation Helper
# Run this AFTER dragging Lux.app to your Applications folder
# ============================================================
echo "====================================="
echo "  Lux — Installation Helper"
echo "====================================="
echo ""

APP="/Applications/Lux.app"
BIN="$APP/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL="${BIN}_real"

# Step 1: Check Lux.app is in Applications
if [ ! -d "$APP" ]; then
    echo "⚠️  Lux.app not found in /Applications."
    echo "Please drag Lux.app to your Applications folder first, then run this script again."
    echo ""
    read -n 1 -p "Press any key to close..."
    exit 1
fi

echo "✅ Found Lux.app in /Applications"
echo ""

# Step 2: Remove quarantine (fixes 'damaged' / Gatekeeper block)
echo "Step 1/3: Removing macOS quarantine..."
sudo xattr -cr "$APP"
echo "✅ Quarantine removed"
echo ""

# Step 3: Set up elevation wrapper for lux_core
echo "Step 2/3: Setting up elevation (lux_core needs root for TUN mode)..."

# The wrapper script (lux_core) calls sudo lux_core_real
# lux_core_real is the actual binary — needs root:wheel + setuid
if [ -f "$REAL" ]; then
    # Already set up — just fix permissions in case
    sudo chown root:wheel "$REAL"
    sudo chmod 770 "$REAL"
    sudo chmod u+s "$REAL"
    echo "✅ lux_core_real permissions fixed"
elif [ -f "$BIN" ]; then
    # First install — move binary to _real, create wrapper
    sudo mv "$BIN" "$REAL"
    printf '#!/bin/bash\nexec sudo "%s" "$@"\n' "$REAL" | sudo tee "$BIN" > /dev/null
    sudo chmod 755 "$BIN"
    sudo chown root:wheel "$REAL"
    sudo chmod 770 "$REAL"
    sudo chmod u+s "$REAL"
    echo "✅ lux_core wrapper created"
else
    echo "⚠️  lux_core binary not found — the app may be corrupted"
fi
echo ""

# Step 4: Set up passwordless sudo for lux_core_real
echo "Step 3/3: Setting up passwordless sudo (so Lux doesn't ask for password)..."
USER_=$(whoami)
SUDOERS_LINE="$USER_ ALL=(root) NOPASSWD: $REAL *"
echo "$SUDOERS_LINE" | sudo tee /etc/sudoers.d/lux_core > /dev/null
sudo chmod 0440 /etc/sudoers.d/lux_core
sudo visudo -c -f /etc/sudoers.d/lux_core 2>/dev/null && echo "✅ Passwordless sudo configured" || echo "⚠️  sudoers setup failed — Lux will prompt for password on connect"
echo ""

echo "====================================="
echo "✅ Installation complete!"
echo "Open Lux from your Applications folder."
echo "====================================="
echo ""
read -n 1 -p "Press any key to close..."
