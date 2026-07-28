# Lux Development Journal

## Current Version: 1.45.7 (feat/stable branch)

---

## FIXED — What was done and why

### 🔴 Critical Stability

#### Load balancer deleted (Go) — v1.45.0
**Problem:** lux_core had a multi-interface load balancer (en0/en7). When a dead Ethernet cable was plugged in, the balancer marked en7 unhealthy every 10s, failed over to en0 (WiFi), then "recovered" en7 (because ARP responded at layer 2), switched back to dead en7 — infinite loop that killed the proxy.
**Fix:** Deleted the balancer entirely. Always use OS default interface. The OS kernel handles multi-interface routing correctly.

#### Go-side watchdog deleted (Go) — v1.45.0
**Problem:** Go had its own 10-second watchdog that probed the upstream proxy TCP port. When it failed, it called `manager.Stop()` + `manager.Start()`. This fought with Flutter's NetworkDetector which switched to `bypass_all` — Go watchdog saw the proxy unreachable in bypass mode and kept restarting back to `proxy_all`. Infinite fight.
**Fix:** Deleted. Flutter owns proxy lifecycle entirely.

#### NetworkDetector false bypass_all switches — v1.45.3 + v1.45.4
**Problem 1:** NetworkDetector probed the corporate proxy IP directly (e.g. `10.8.0.1:8082`). During lux_core startup, the TUN interface takes ~10s to come up. Probe timed out → NetworkDetector thought "not on corporate network" → switched to `bypass_all` → killed preproxy.
**Fix (v1.45.3):** `_safeDetect()` wrapper skips detection if lux_core started less than 10s ago.

**Problem 2:** The probe was hardcoded to the configured proxy server address — wouldn't work if a user's proxy was at a different IP.
**Fix (v1.45.4):** NetworkDetector now uses the PAC/WPAD URL as the primary probe target. Every corporate network serves WPAD from the LAN — unreachable from home. More universal and more reliable than probing the proxy server directly.

#### PAC server detection keeps clearing/reapplying — v1.45.0
**Problem:** The Go watchdog was stopping/starting lux_core every few seconds when health checks failed (due to load balancer chaos), which cleared and re-applied PAC rules on every restart. Intranet domains briefly routed through the upstream proxy during the PAC gap.
**Fix:** Removing the Go watchdog and load balancer eliminated the restart loop.

---

### 🟡 Connection Reliability

#### Force stop+start after power outage — v1.44.77 (personal/all-features)
**Problem:** After a power cut, lux_core reported `isStarted=true` but all connections were stale (established before the outage). Flutter saw 500 "already started" and returned early — internet stayed dead.
**Fix:** When `start()` returns 500 and `isStarted=true`, force a stop+start cycle to clear stale connections.

#### Reconnect debounce + concurrency guard — v1.44.88
**Problem:** WiFi flapping 12 times in 5 minutes triggered 12 concurrent reconnect loops, each calling `stop()` and `start()`.
**Fix:** 10-second debounce + `_reconnectInProgress` mutex.

#### Watchdog calls NetworkDetector before stop+start — v1.45.x
**Problem:** When health checks failed, the watchdog immediately did stop+start instead of first checking if we'd moved to a home network.
**Fix:** Watchdog calls `_safeDetect()` first. If NetworkDetector switches to bypass_all, skip the stop+start.

---

### 🟠 Updater / Relaunch

#### Updater relaunch using one-shot LaunchAgent — v1.45.7
**Problem:** Every relaunch method tried from root context failed on macOS Sequoia:
- `launchctl asuser $UID open -a Lux.app` — silent failure, app never appeared
- `su - user -c "open -a Lux.app"` — worked in testing but unreliable in practice
- `osascript tell Finder to open` — failed from launchctl context
**Root cause:** macOS Sequoia requires apps to be launched from a proper user GUI session. Root daemon context doesn't have one.
**Fix:** Write a temporary `io.github.lux.relaunch.plist` to the user's LaunchAgents directory, `launchctl load -w` it (fires immediately with `RunAtLoad=true`), wait 3s, then unload and delete. Confirmed working in test.
**Note:** This is non-standard but functional. The proper fix would be to make the updater run as the user (not root), like Sparkle does. Left as a future improvement.

#### Updater lux_updater.sh volume name hardcoded — v1.45.7
**Problem:** The installed `lux_updater.sh` had `SRC="/Volumes/Lux 1.45.6/Lux.app"` hardcoded. Every subsequent update failed with `ditto: Cannot get the real path`.
**Fix:** Uses `find /Volumes -maxdepth 2 -name "Lux.app"` to detect the mounted volume dynamically.

#### elevate() ran osascript unnecessarily — v1.45.6
**Problem:** `_isSudoersConfigured()` tried to run `sudo -n lux_core_real --help`. This failed when lux_core was dead (permission denied even though sudoers was correct), causing elevate() to show the admin password dialog on every startup after a crash.
**Fix:** Use `sudo -n -l lux_core_real` (list only, never runs the binary). Returns 0 if NOPASSWD is configured, regardless of whether lux_core is running.

#### sudoers lux_proxy_apply.sh missing wildcard — v1.45.2 + v1.45.6
**Problem 1:** The sudoers rule had `NOPASSWD: .../lux_proxy_apply.sh` without `*`, so `sudo -n bash lux_proxy_apply.sh 127.0.0.1:1090` failed (arguments not allowed). Fell through to osascript → password prompt on every connect.
**Problem 2:** The `elevate.dart` setup script also wrote sudoers without the wildcard, so fresh installs were broken from day one.
**Fix:** Added `*` wildcard to both the installed sudoers file and the elevate.dart template.

#### Updater script ownership — v1.44.87
**Problem:** After security hardening, `lux_updater.sh` was made root-owned. Flutter couldn't overwrite it with the new version's path → sudo fell through to osascript.
**Fix:** `lux_updater.sh` stays user-owned (Flutter writes it). Only `lux_proxy_apply.sh` and `lux_proxy_clear.sh` are root-owned (static scripts).

---

### 🟢 Feature Additions

#### UDP DIRECT fallback — v1.45.5
**Problem:** lux_core silently converted UDP traffic to TCP when the upstream proxy was an HTTP CONNECT proxy (which never supports UDP relay). This broke Zoom calls, WhatsApp voice, and WebRTC.
**Fix:** Two-layer fix in `internal/conn/udp.go`:
1. Proactive check: if `!connDialer.SupportUDP()`, immediately dial DIRECT instead.
2. Reactive check: if `ListenPacketContext` returns `"no support"` error, fall back to DIRECT.
Zoom UDP now flows direct to Propulsão gateway, bypassing Squid.

#### PAC-based network detection — v1.45.4
NetworkDetector probes the WPAD/PAC URL instead of the proxy server IP. More universal — works for any corporate network, not just the current one.

#### Automated test suite — v1.45.1
- `bash scripts/test_all.sh` — runs all tests safely without disrupting proxy
- `scripts/test_functional.sh` — tests actual app behaviour (traffic routing, env vars, cert trust, PAC, auto-connect, auth failures)
- `scripts/test_network_switch.sh` — connectivity simulation (safe by default, `--destructive` for stop/start)
- `scripts/test_update_cycle.sh` — update cycle validation (appcast, DMG integrity, sudoers)
- Go unit tests: PAC parser, TCP conn, rule switching
- Flutter unit tests: socket probe/timeout

#### Debug logging — v1.45.1
- `lux_core -debug` flag enables DEBUG log level
- NetworkDetector logs every probe and decision to `flutter_app.log` under `[NET-DETECT]`
- ProxyConfigurator logs every apply/clear/sudo call
- CoreManager.start()/stop() now logged

#### Functional test suite non-destructive — v1.45.1
All tests are read-only. Stop/start tests require `--destructive` flag. Running tests does not disrupt the proxy connection.

#### Surgical cleanup branch (feat/stable) — v1.45.0
Started from personal/all-features with targeted Go-side cuts:
- Load balancer deleted
- Go watchdog deleted  
- MITM feature stubbed (was broken, never worked in production)
- NetworkDetector rewritten: 200 lines → 50 lines, stateless, no timers
- CA env vars fixed: `SSL_CERT_FILE` added, `NODE_EXTRA_CA_CERTS` path corrected

---

## LEFT TO DO — Known issues and planned features

### 🔴 Critical / High Priority

#### Updater architecture (proper fix)
**Current state:** Updater runs as root (because lux_core setup needs root). This makes post-install relaunch inherently difficult.
**Proper fix:** Separate concerns. The update installation (replacing `/Applications/Lux.app`) doesn't need root — the user owns the app. Only lux_core elevation needs root. The updater should run as the user and call the privileged helper only for the elevation step.
**Why not done yet:** Requires refactoring the updater to have a user-space install path separate from the elevation path.

#### `!` negation in exclusion rules (Preproxy parity)
**What:** Allow `*.example.com, !gw.example.com` in the bypass list — exclude all subdomains except one specific host.
**Why needed:** Preproxy v1.5.1 has this. Common need in corporate environments where you want to bypass proxy for an internal domain but not its gateway.
**Scope:** Rules page UI + Go-side rule matching.

#### Proxy via PAC URL (add proxy from wpad.dat instead of IP)
**What:** Allow adding a proxy by entering a PAC URL instead of requiring an explicit IP:port. lux_core fetches the PAC, finds the proxy address, and uses it.
**Why needed:** Many corporate environments publish the proxy address only via WPAD/PAC. Users shouldn't need to know the IP.
**Scope:** proxy_edit_dialog.dart (new "PAC URL" proxy type) + Go-side proxy handling.

#### NTLM authentication
**What:** Authenticate to the upstream proxy using NTLM (Windows domain authentication).
**Why needed:** Required for Windows Active Directory environments where Squid uses NTLM. Without it, Lux doesn't work in some corporate networks globally.
**Scope:** Go-side HTTP proxy outbound handler. Clash/Mihomo may have existing NTLM support to leverage.

### 🟡 Medium Priority

#### Enterprise mass deployment / config via plist
**What:** Allow pre-configuring Lux via a JSON/plist file, importable via command line. IT departments can deploy Lux pre-configured to all machines.
**Why needed:** Preproxy has this. Makes corporate deployment of Lux viable at scale.
**Scope:** New CLI argument + config import logic.

#### Clean branch (feat/native-ui-clean) sync
The `feat/native-ui-clean` branch (started from igoogolx's v1.40.3) is behind `feat/stable`. Should be synced with all post-1.45.0 fixes before submitting as a PR to igoogolx.

#### Load balancer UI removal
The Settings page still shows a load balancing section (the Go backend no longer supports it). The UI should be removed to avoid confusing users.

#### Preproxy doesn't lose connection when Lux acts up
**Current state:** When Lux stops/starts or crashes, it clears system proxy settings, breaking preproxy's connection. During the ~5s gap, preproxy has no upstream.
**Proper fix:** Don't clear system proxy on crash/restart — only clear on intentional user disconnect. The system proxy pointing to 127.0.0.1:1090 is harmless if nothing is listening.

### 🟢 Nice to Have

#### IPv6 listener
lux_core's local proxy (port 1090) may only listen on IPv4. Preproxy v1.5.1 added IPv6. Some apps use IPv6 loopback.

#### Recent requests → direct preproxy-style diagnostics
Show which app made a request and whether it went PROXY or DIRECT, with timestamp. Connections page partially does this but doesn't show the app name prominently.

#### Graceful mid-auth connection drop (Preproxy 1.5.3 parity)
If the upstream proxy drops the connection mid-authentication handshake, retry gracefully instead of showing an error.

---

## Branch Status

| Branch | Version | Purpose |
|--------|---------|---------|
| `personal/all-features` | 1.45.7 | Production — users get updates from here |
| `feat/stable` | 1.45.7 | Clean branch with all fixes, matches production |
| `feat/native-ui-clean` | 1.45.1 | igoogolx PR candidate — needs sync with latest fixes |

## How to Release

```bash
cd /Users/virgoh/lux
bash scripts/workflows/release.sh "description of change"
# OR
python3 scripts/release.py --notes "description"
```

## How to Run Tests

```bash
bash scripts/test_all.sh                     # all safe tests
bash scripts/test_functional.sh              # detailed functional tests
bash scripts/test_network_switch.sh          # connectivity simulation (safe)
bash scripts/test_network_switch.sh --destructive  # includes stop/start (kills proxy)
bash scripts/test_update_cycle.sh            # update cycle validation
```
