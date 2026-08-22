# Session Journal — 2026-08-20

## Starting State
- Running: Lux 1.50.4 (installed), branch `rebuild/clean-base`
- Repos: `/Users/virgoh/lux-clean`, `/Users/virgoh/itun2socks-clean`, `/Users/virgoh/lux-client-clean`
- Preproxy 127.0.0.1:8079 always available
- Corporate proxy 10.8.0.1:8082 (Arautos do Evangelho)
- LP proxy 192.168.71.254:8082 (reachable via VPN utun7)

## Bugs Found & Fixed

### 1. Per-proxy PAC rules not working (1.50.5 regression)
- **Cause:** Global PAC in match() fallback re-proxied Kiro's already-proxied traffic
- **Fix:** Reverted to per-proxy PAC model (consulted in NewTcpConn, after rule matches)
- **Released:** 1.50.7

### 2. Stale `broken` flag on LP rules
- **Cause:** `markBroken()` only ran on mutations, never on `Read()`. Rules marked broken during migration stayed broken forever
- **Fix:** Derive `broken` flag in `Read()` every time
- **Released:** 1.50.7

### 3. Elevation fails after update (binary missing)
- **Cause:** Worktree recreation left `assets/bin/` empty (gitignored). Release built Flutter with no core binary
- **Fix:** `release.sh` now refuses to build if `assets/bin/lux_core` is missing
- **Released:** 1.50.18

### 4. Elevation fails on fresh install (quarantine)
- **Cause:** macOS quarantine attribute blocks `mv`/`chmod` on downloaded apps
- **Fix:** `xattr -cr` inside the elevation osascript block (which has root)
- **Released:** 1.50.9

### 5. Elevation fails after update (stale lux_core_real)
- **Cause:** Updater replaces the .app bundle; lux_core is a binary again but _real exists from previous install. `mv` refuses when target exists
- **Fix:** Elevation script handles all three states: A) wrapper exists, B) binary + stale _real, C) fresh install
- **Released:** 1.50.17

### 6. LP proxy unreachable from lux_core
- **Cause:** `DefaultInterface` set globally to `en0` by the interface monitor. All dials (including proxy outbound) were bound to en0. LP is only reachable via utun7 (VPN)
- **Fix:** Proxy connections pass `WithInterface("")` so kernel routes freely; only DIRECT connections bind to `defaultInterface`
- **Released:** 1.50.28

### 7. LP delay test fails in UI
- **Cause:** Same DefaultInterface issue in the URLTest code path
- **Fix:** Clear and restore DefaultInterface around URLTest call
- **Released:** 1.50.29

### 8. StrictRoute: true prevented VPN-reachable proxies
- **Cause:** TUN with StrictRoute forced ALL traffic through it, including lux_core's own outbound
- **Fix:** Changed to `StrictRoute: false`
- **Released:** 1.50.28

### 9. NODE env vars not set for Electron apps (Antigravity)
- **Cause:** `launchctl setenv` from root (lux_core runs as root via sudo) doesn't reach user's GUI session
- **Fix:** Moved env var setting to Flutter toggle handler (runs as user)
- **Released:** 1.50.33

### 10. Core toggle turns off unexpectedly
- **Cause:** Nothing polled `isStarted` — when the core stopped for any reason, it stayed off indefinitely
- **Fix:** 30-second watchdog timer in Flutter; restarts core if `userWantsRunning` is true
- **Released:** 1.50.30

### 11. Rule edit returns 500 for named proxies
- **Cause:** Flutter sent proxy display name ("LP") instead of UUID as the policy. Go validation rejected it
- **Fix:** Maintain a name→id map, pass `proxyId` explicitly
- **Released:** 1.50.27

### 12. Drag handle overlaps delete button in rules page
- **Cause:** ReorderableListView default handles render on the right side, same space as action buttons
- **Fix:** buildDefaultDragHandles=false, custom drag_indicator icon on left via ReorderableDragStartListener
- **Released:** 1.50.16 (original), 1.50.27 (rebuild)

### 13. Credential expiry dialog missing username field
- **Cause:** Only password field was shown
- **Fix:** Added username field + 5-minute grace period that stops core if ignored
- **Released:** 1.50.32

## Features Added

### Detect Proxy from WPAD
- Button on proxy page → probes DHCP/scutil/gateway for PAC → regex-extracts PROXY entries
- Prompts for credentials + password type before adding
- Checks SSL cert interception and offers to trust corporate CA
- **Released:** 1.50.13, 1.50.14, 1.50.15

### Credential Expiry Flow
- Go side tries each proxy before prompting user
- WebSocket event `credential-expired` / `proxy-switch`
- Flutter brings window to front with re-auth dialog
- 5-minute grace period auto-disconnect
- **Released:** 1.50.10, 1.50.11, 1.50.32

### Blackbox Flight Recorder
- Ring-buffer (500 events) persisted to `blackbox.json`
- Records: manager start/stop, proxy failures, auth failures, credential expiry, failover, connectivity lost/restored
- Health check every 30 seconds
- API: GET /blackbox, GET /blackbox/recent
- **Released:** 1.50.16

### Telemetry (Error Reporting)
- Wired to Apps Script endpoint
- `telemetryError()` flushes immediately for critical events
- Elevation failures, credential expiry, blackbox events reported
- `followRedirects: false` for Apps Script 302 responses
- **Released:** 1.50.19, 1.50.20

### Pre-TUN Bypass
- Auto-excludes ALL proxy IPs from TUN routing (not just selected)
- Explicit `bypassCidrs` setting for additional IPs
- Windows: WFP per-process bypass for PROCESS,x,DIRECT rules
- **Released:** 1.50.25, 1.50.26

### Proxy Chaining (via field)
- `HttpOption` gains `Via`, `ViaUser`, `ViaPassword` fields
- `DialContext` first CONNECTs to the upstream proxy, then through it to the target
- Not yet exposed in UI
- **Released:** 1.50.28

### Per-Proxy PAC
- PAC registry keyed by proxy id (replaces global singleton)
- Consulted in NewTcpConn after GetProxy resolves target proxy
- If PAC says DIRECT, bypasses the proxy
- Custom rules always override PAC
- **Released:** 1.50.7

### DNS-MAP UI Enhancement
- Edit dialog shows separate "Domain" and "Resolve to IP" fields
- List displays `domain → ip` instead of raw semicolons
- **Released:** 1.50.22

### Borderless Window with Traffic Lights
- `TitleBarStyle.hidden` + `windowButtonVisibility: true` on macOS
- 70px left padding so traffic lights don't overlap toolbar
- **Released:** 1.50.23, 1.50.24

### Core Watchdog
- 30-second timer polls `getIsStarted()`
- Only restarts if `userWantsRunning` (respects deliberate toggle-off)
- Set by toggle-on, autoConnect, and cleared by toggle-off / grace period
- **Released:** 1.50.30

### NODE/Proxy Env Vars on Toggle
- Sets HTTP_PROXY, HTTPS_PROXY, NODE_EXTRA_CA_CERTS, NODE_TLS_REJECT_UNAUTHORIZED, NODE_OPTIONS via launchctl
- Runs from Flutter (user session), not Go (root session)
- Cleared on toggle-off
- **Released:** 1.50.33

### Release Page
- Published at https://lux-proxy-release.lux.here.now/
- macOS + Windows download links (GDrive)
- Previous Versions via Apps Script revision proxy
- SHA-256 checksums
- here.now workspace `lux` (public access)

## Architecture Decisions

- **StrictRoute: false** — required for proxies reachable only via VPN
- **DefaultInterface: empty for proxy dials** — kernel routes freely to VPN/physical
- **Env vars from Flutter, not Go** — launchctl setenv only works in calling user's session
- **Watchdog in Flutter, not Go** — the Flutter app knows user intent (toggle state)
- **Elevation handles 3 states** — wrapper exists, binary+stale_real, fresh install
- **release.sh safety check** — refuses to build without lux_core in assets/bin

## Current State
- **Version:** 1.50.33 (macOS published), 1.50.32 (Windows published)
- **Branch:** `rebuild/clean-base` on both repos
- **lux-clean:** 9228497
- **itun2socks-clean:** 536c143
- **Appcast:** 1.50.33, Windows entry preserved
- **Kiro issue:** 503/403 from Squid blocking *.kiro.dev — needs Squid ACL fix (not a Lux issue)

## Pending / Not Done
- Cloudflare Worker for direct downloads (bypass GDrive virus scan)
- DNS-MAP modal UX (separate session)
- Per-proxy PAC in UI (pacUrl field exists in config, no UI to set it)
- Route-change handler for PAC refresh on WiFi/VPN switch
- Windows agent needs to build 1.50.33
