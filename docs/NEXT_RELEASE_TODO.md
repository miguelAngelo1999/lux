# Next Release TODO (`v1.50.127+`)

## Ready in `rebuild/clean-base` (queued for next release build)

- [x] **Tray version label (`716ebcc`):** Replaced hardcoded `Lux 1.41.0` in [tray.dart](file:///Users/virgoh/lux/lib/tray.dart) with dynamic `getAppVersionString()` (cached). Ready to ship in next release.

## Pending / To Verify Before Promoting Stable

- [ ] Confirm `http://wpad/wpad.dat` works on `192.168.86.xx` house PCs after `v1.50.125+` (if still `no such host`, check `nslookup wpad` / `ipconfig /all` there and add gateway / DHCP Option 252 fallback if needed).
- [ ] Confirm macOS in-app updater (`.126 → .127+`) no longer triggers the `"access files on a removable volume"` TCC prompt on Macs with external/USB drives connected.
- [ ] Decide when to promote beta (`v1.50.126` / `v1.50.127`) to `stable` (`appcast.json`).
