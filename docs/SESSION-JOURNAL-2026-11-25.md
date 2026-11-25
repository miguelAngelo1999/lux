# Session Journal — 2026-11-23 to 2026-11-25 — Windows VoIP/Mixed Mode, LuxCoreService, UWP Loopback, WPAD DNS & macOS Updater Fixes (`v1.50.121` → `v1.50.126`)

## Summary

A multi-day stabilization and UX overhaul spanning **six beta releases (`v1.50.121` through `v1.50.126`)** plus one queued fix (`716ebcc`) across both repositories (`lux` and `itun2socks-clean`), verified end-to-end with unit/widget tests and live testing inside the **`Windows 11 (1)`** Parallels VM:

1. **Fixed WhatsApp voice/video calls in Windows Mixed mode** (two root causes: Fake-IP UDP NAT + dual-stack IPv4-mapped IPv6 unmapping & Winsock `WSAECONNRESET` suppression).
2. **Fixed Windows live elevation (`System → Mixed` HTTP 403) and slow-UAC `/ping` timeouts.**
3. **Built `LuxCoreService`**, a native Windows `LocalSystem` service supervisor for **zero-UAC restarts** across all proxy modes (including `System` mode), with per-user SID WinINET registry updates (`-user_sid`), admin-only NTFS SID ACLs, and automatic creation inside the Inno Setup installer.
4. **Added graceful UAC-cancelled fallback** to non-elevated `System` mode with a localized (EN / PT-BR / ES / IT / FIL / ZH) non-blocking banner and Settings status row, plus fixed silent UWP `CheckNetIsolation` loopback failures (`174/174` packages exempted including `AppleInc.iCloud_*` and `Microsoft.WindowsStore_*`).
5. **Fixed single-label WPAD (`http://wpad/wpad.dat`) DNS resolution on Windows** across Disconnected, System, and Mixed modes.
6. **Eliminated the macOS `"access files on a removable volume"` TCC prompt** during in-app updates by mounting DMGs onto a private temp mountpoint instead of scanning `/Volumes`.
7. **Replaced the hardcoded `Lux 1.41.0` tray menu label** with dynamic app version resolution (queued in `docs/NEXT_RELEASE_TODO.md` for `v1.50.127+`).

- **Branch:** `rebuild/clean-base`
- **Remotes:** `github.com/miguelAngelo1999/lux` & `github.com/miguelAngelo1999/itun2socks`
- **Live channels at end of session:** `stable = 1.50.120`, `beta (Latest) = 1.50.126`

---

## 1. WhatsApp Calls Blocked in Windows Mixed Mode (`v1.50.121` + `v1.50.124`)

### Symptoms & Investigation
- In Windows **Mixed** mode, WhatsApp calls stuck on "Connecting" and failed to carry media.
- **First pass (`itun2socks-clean` `7fed286`, shipped in `v1.50.121`):**
  - Implemented bidirectional Fake-IP (`198.18.0.0/15`) ↔ Real-IP NAT inside `CopyablePacketConn` (`internal/conn/udp.go`) so connected UDP sockets accept replies rewritten back to the Fake-IP they dialed.
  - Added a direct-UDP STUN reachability auto-probe (`internal/executor/udp_probe.go`) so firewalled corporate networks fall back cleanly to WFP fast-fail UDP block (triggering TURN-over-TCP) while open networks keep direct UDP relay.
  - Built Windows `lux_core.exe` with `-tags with_gvisor` so `sing-tun` runs its mixed TCP-system / UDP-gVisor stack.
- **Challenge — calls STILL failed in Mixed mode after `v1.50.123`!**
  - Running a targeted live Python STUN matrix inside `Windows 11 (1)` immediately split the problem in two:
    - Domain STUN (`stun.cloudflare.com`, `stun.l.google.com` via Fake-IP): **PASSED in 19–24ms**.
    - **Raw IPv4 STUN (`162.159.207.0:3478`, `74.125.250.129:19302` — unconnected & connected): 100% FAILED (timed out)!**
  - `core.log` revealed the exact smoking gun:
    ```json
    {"msg":"[UDP], relay socket [::]:63706 opened for 162.159.207.0:3478"}
    {"msg":"[UDP], download finished: bytes=0, err=<nil>, remote address: 162.159.207.0:3478"}
    {"msg":"[UDP], upload finished: bytes=20, err=io: read/write on closed pipe"}
    ```
  - **Root cause:** Outbound direct UDP sockets bind dual-stack (`[::]:port`), so `ReadFrom` returns IPv4 peers as **IPv4-mapped IPv6** (`::ffff:162.159.207.0:3478`, where `Is4In6() == true`). For Fake-IP destinations, `lookupFakeForReal` replaced `src.Addr` with pure IPv4 `netip.AddrFrom4(fake4)`, so gVisor accepted it. For **raw IPv4 destinations** (all WhatsApp ICE/STUN/media relay IPs received via TCP signaling!), `lookupFakeForReal` returned `false`, leaving `src.Addr` as `::ffff:a.b.c.d`. `sing-tun`'s gVisor IPv4 UDP endpoint rejected `Is4In6()` immediately and terminated `bufio.CopyPacket` with `bytes=0, err=<nil>` in `<1ms`.
  - **Three additional latent UDP bugs found in the same inspection:**
    1. **Winsock `WSAECONNRESET` (`10054`) ICE-probe killer:** Because `sing` shares one outbound UDP socket per client source port across all ICE candidates, an ICMP Port Unreachable from a single unreachable peer causes Windows `WSARecvFrom` to return `WSAECONNRESET`, tearing down the entire call's UDP relay unless `SIO_UDP_CONNRESET = FALSE` is set via `WSAIoctl` and transient `WSAECONNRESET` is ignored in `ReadPacket`.
    2. **`UdpTracker` value-copy of `sync.RWMutex`:** `NewUDPTracker(*localConn, ...)` copied `CopyablePacketConn` (which holds `natMu sync.RWMutex`) by value, and did not track `ReadPacket`/`WritePacket` byte counts.
    3. **DNS loop risk on Fake-IP UDP lookup:** `executor.New()` cleared `cResolver.DefaultResolver = nil`, causing `CopyablePacketConn.resolveRealIPv4` to fall back to OS DNS (which loops into Wintun's `10.255.0.2` when `hijackDns` is enabled).

### Fix (`itun2socks-clean` `75d173a`, shipped in `v1.50.124`)
- `internal/conn/udp.go`: Unconditionally unmap `src.Addr` (and `destination.Addr`) to pure IPv4 (`Is4() && !Is4In6()`) for both raw IPv4 and Fake-IP flows; bumped `udpReadTimeout` to `60s`; switched default resolver to `dns.LookupLocalIPv4`.
- `internal/dns/client.go`: Added `LookupLocalIPv4` backed by `dnsMap[PolicyDirect]` (bound to physical NIC).
- `pkg/clash/component/dialer/bind_windows.go`, `internal/conn/udp_windows.go`, `internal/conn/udp_other.go`: Set `SIO_UDP_CONNRESET = 0` (`0x9800000C`) via `WSAIoctl` on Windows UDP sockets and ignored transient `WSAECONNRESET` in `ReadPacket`.
- `internal/tunnel/statistic/tracker.go`, `internal/tunnel/udp.go`: Embedded `*conn.CopyablePacketConn` by pointer and added `ReadPacket`/`WritePacket` byte accounting.
- `internal/conn/udp_nat_test.go`: Added deterministic `TestCopyablePacketConn_RawIPv4Unmaps4In6FromDualStackSocket`.

### Verification
- Live VM STUN/ICE test suite on `Windows 11 (1)`: **7/7 passed** in 10–30ms (raw IPv4 Cloudflare/Google unconnected & connected, domain STUN, and multi-peer shared-socket ICE with an unreachable probe).
- Real live WhatsApp voice call tested by user in real Mixed mode (`utun0` `10.255.0.1` + WinINET `127.0.0.1:1090`): confirmed clear two-way audio (`10.255.0.1:52857 ↔ 10.87.132.197:41207`, `277 KB up / 405 KB down`, zero warnings/drops in `core.log`). *(The static dots in WhatsApp Beta's floating mini PiP widget turned out to be a WhatsApp Beta UI quirk — audio worked cleanly.)*

---

## 2. Windows Live Elevation & Slow-UAC `/ping` Timeout (`v1.50.122`)

### Challenges
- Switching `System → Mixed` in Settings threw HTTP `403 NotElevated` because `lux_core.exe` was still running non-elevated and didn't elevate live.
- Killing and restarting Lux elevated caused `unable to ping core` because PowerShell `Start-Process -Verb RunAs` returned immediately while the user was typing admin credentials, consuming the 30s `/ping` budget before `lux_core.exe` even spawned.
- `CoreManager.makeRequestUntilSuccess` recursed on non-200 responses, and the watchdog fought controlled restarts/UAC cancellations.

### Fix (`lux` `8396530`, shipped in `v1.50.122`)
- `lib/util/process_manager.dart`: Launched `lux_core.exe` via UTF-16LE `-EncodedCommand` with `$ProgressPreference = 'SilentlyContinue'` waiting for UAC approval or cancellation (`Win32Exception.NativeErrorCode == 1223`) *before* `/ping` begins.
- `lib/core/core_manager.dart`, `lib/home.dart`: Live elevation on mode switch & `start()`, graceful `POST /manager/exit` shutdown before respawn, automatic non-elevated System-mode recovery on UAC cancel, fixed `makeRequestUntilSuccess` loop, and added watchdog guards (`isRestartingCore`, immediate stop on cancel/403).
- `test/windows_elevation_test.dart`: Added full unit test suite with a local fake `lux_core` HTTP server.

---

## 3. Native Windows Service `LuxCoreService` — Zero-UAC Restarts (`v1.50.123`)

### Challenges
- Prompting UAC on every reboot or app launch is painful (especially for non-admin corporate users needing IT credentials).
- Running a `LocalSystem` service introduces two pitfalls:
  1. **Privilege-escalation security:** A standard user must never be able to overwrite the binary executed by `LocalSystem`.
  2. **Session 0 registry isolation:** `LocalSystem` writing `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings` writes to `.DEFAULT`, not the logged-in desktop user's hive.
  3. **Localized Windows group names:** Using `"Administrators"` or `"Users"` with `icacls` breaks on PT-BR (`Administradores`, `Usuários`) and ES Windows installations.

### Fix (`itun2socks-clean` `f6a228c`, `lux` `750f7d1`, shipped in `v1.50.123`)
- Go supervisor (`service_common.go`, `service_windows.go`, `service_other.go`, `service_test.go`, `main.go`): Added `-service` mode running as `LuxCoreService` (`AUTO_START`, `LocalSystem`) exposing an authenticated loopback control API (`GET /health`, `POST /start-core`, `POST /stop-core`) with port/token/SHA-256 metadata in `C:\ProgramData\LuxService\service.json`.
- Per-user registry targeting (`pkg/sysproxy/user_registry_windows.go`, `sysproxy_windows.go`, `env_windows.go`): Added `-user_sid=<SID>` so Session-0 `lux_core.exe` writes directly to `HKEY_USERS\<SID>` (combined with Session-1 WinINET `InternetSetOptionW` refresh via `dart:ffi` in `lib/util/proxy_env.dart`).
- Security & localization (`lib/util/windows_service.dart`, `lib/util/process_manager.dart`): Installed binaries in `C:\Program Files\LuxService\` locked via locale-independent well-known SIDs (`*S-1-5-18`, `*S-1-5-32-544`, `*S-1-5-32-545`), verified SHA-256 on launch, and confirmed non-admin writes fail with `PermissionError`.

---

## 4. Elevate Once for All Modes (`System` Included) + Graceful UAC Fallback + UWP Loopback (`v1.50.124`)

### Challenges
- Skipping `LuxCoreService` in `System` mode broke Microsoft Store / UWP apps (e.g. iCloud for Windows, Microsoft Store) because non-elevated `lux.exe` ran `CheckNetIsolation.exe ... 2>$null`, which silently failed with `Access Denied` while logging `exit=0`.
- `clearUWPLoopbackExemptions()` ran `CheckNetIsolation LoopbackExempt -c` on every disconnect, wiping all Windows UWP loopback exemptions system-wide and causing reconnect races.
- Users without admin rights (or who cancel UAC) must still be able to browse immediately without a blocking error screen or repeat UAC nags on every boot.

### Fix (`itun2socks-clean` `75d173a`, `lux` `4aaf41c`, shipped in `v1.50.124`)
- **All-mode elevation & installer integration:**
  - `lib/core/core_manager.dart` (`startInitialCore`, `enableWindowsService`, `_ensureWindowsCoreElevation`), `lib/home.dart`: Always uses `LuxCoreService` across `System`, `Mixed`, and `TUN` modes (zero UAC once installed), and keeps `LuxCoreService` active on `Mixed → System` switches instead of downgrading.
  - `windows/packaging/exe/setup.iss`: `InstallOrUpdateLuxCoreService()` now creates/updates, locks SID ACLs, and starts `LuxCoreService` during every elevated install/upgrade so first launch after install needs **zero** UAC prompts.
- **Graceful fallback & localized UI:**
  - `lib/core/core_config.dart`, `lib/model/app.dart`: Persists `windowsServiceDeclined` in `lux_prefs.json` and exposes `AppStateModel.windowsLimitedMode`. Cancelling UAC automatically starts non-elevated `System` mode (reverting saved Mixed/TUN if needed) with no repeat UAC prompt on subsequent launches.
  - `lib/widget/windows_service_banner.dart`, `lib/dashboard.dart`, `lib/pages/settings_page.dart`, `assets/translations.json`: Added non-blocking Dashboard warning banner and Settings **Background Service** status row with **"Enable now"** button, localized across EN, PT-BR, ES, IT, FIL, and ZH.
- **UWP loopback fixes:**
  - `pkg/sysproxy/loopback_windows.go`, `pkg/sysproxy/sysproxy.go`, `main.go`: Uses `Get-AppxPackage -AllUsers -PackageTypeFilter All` with deduplication, `HideWindow: true`, elevation check, mutex + 5-min cooldown, real `exempted/attempted` counts, runs on elevated core startup and `sysproxy.Set()`, and stopped calling `CheckNetIsolation LoopbackExempt -c` on normal disconnect.
  - `lib/home.dart`: Removed the misleading non-elevated `CheckNetIsolation ... 2>$null` call; delegates to elevated `lux_core` and logs clearly in limited mode.
- **Tests & live VM verification:**
  - Added `test/windows_startup_fallback_test.dart` (**132/132** Flutter tests passing).
  - Live VM checks: clean-slate installer created `LuxCoreService` from scratch; zero-UAC `System` mode exempted **174/174** UWP packages (confirmed `appleinc.icloud_nzyj5cx40ttqa` and `microsoft.windowsstore_8wekyb3d8bbwe` listed before AND after disconnect); UAC-declined limited mode reverted to non-elevated `System` mode with HTTP 204 browsing through `127.0.0.1:1090` and PT-BR banner visually verified.

---

## 5. Single-Label WPAD (`http://wpad/wpad.dat`) DNS Resolution on Windows (`v1.50.125`)

### Symptoms & Root Cause
- Opening **Active PAC Rules** on `Proxy-Arautos (copy)` (`http://wpad/wpad.dat`) in Windows `System` mode failed with:
  `fetch http://wpad/wpad.dat: Get "http://wpad/wpad.dat": dial tcp: lookup wpad: no such host`
  (reported on a `192.168.86.xx` house PC and reproduced live on the `10.60.1.240` VM).
- Live VM diagnosis revealed why `nslookup wpad` succeeded (`10.60.1.1`) while `ping wpad` and Go's `net.DefaultResolver` both failed:
  1. When Windows has empty `Primary DNS Suffix` and `Connection-specific DNS Suffix`, Win32 `GetAddrInfoW` (`Dnscache`) **refuses to forward single-label hostnames (`wpad`) to the configured DNS server (`10.60.0.1`)**, stalling in LLMNR/NetBIOS before failing.
  2. `pac.SetLocalLookup(...)` was only wired inside `newTun()`, leaving `localLookup == nil` in `System` mode and while disconnected.
  3. Even in `newTun()`, `pac.DefaultRegistry.Update` ran before `conn.UpdateProxy(config.Proxy)` (so `PolicyDirect` was empty), and `pkg/clash/dns/system.go` forgot to refresh its local `clients` slice after `s.update()`.

### Fix (`itun2socks-clean` `a32befc`, shipped in `v1.50.125`)
- `internal/pac/dns_servers_windows.go`, `dns_servers_other.go`, `dns_fallback.go`, `evaluator.go`: Added direct UDP/53 queries to physical adapter DNS servers (using `winipcfg.GetAdaptersAddresses` on Windows, skipping `utun*`/`Wintun`/`10.255.0.2`, prioritizing private LAN DNS servers, skipping public resolvers like `1.1.1.1` for single-label names, and trying exact `host.` plus adapter DNS suffixes). For single-label names, runs *before* `net.DefaultResolver` (~2ms vs 2–4s LLMNR stall).
- `internal/executor/executor.go`, `pkg/clash/dns/system.go`: Moved `conn.UpdateProxy(config.Proxy)` ahead of `pac.DefaultRegistry.Update` and refreshed `clients` under lock after `s.update()`.
- `internal/pac/dns_fallback_test.go`: Added mock UDP DNS + HTTP Host-header unit tests.
- **Live VM verification (`Windows 11 (1)`):** Tested `pac-rules` and `pac-test` in **Disconnected**, **System**, and **Mixed** modes — all 3 fetched **20,111 bytes**, parsed **70 rules**, and resolved `google.com → PROXY 10.8.0.1:8082` and `mail.icloud.com → DIRECT` with zero errors.

---

## 6. macOS Updater Removable-Volume TCC Prompt (`v1.50.126`)

### Symptom & Root Cause
- Updating `.124 → .125` on an Intel Mac triggered:
  `"Lux" deseja ter acesso a arquivos em um volume removível.`
- Root cause in `lib/util/updater.dart`: the macOS updater mounted the DMG into `/Volumes` and ran `find /Volumes -maxdepth 2 -name Lux.app -type d`. Walking `/Volumes` opened every mounted external/USB volume on the Mac, triggering macOS `kTCCServiceSystemPolicyRemovableVolumes` on every update (re-prompted each release because the app is ad-hoc signed).

### Fix (`lux` `bad5d91`, shipped in `v1.50.126`)
- `lib/util/updater.dart`: Added `buildMacOsDmgAttachArgs` and `findMacOsAppInMountPoint` to mount the DMG at a private temp directory (`${tmp.path}/lux_dmg_mount_<ts>`) with `-mountpoint` and locate `Lux.app` directly inside `try/finally` (always detaching and deleting the temp mount dir), **never listing or scanning `/Volumes`**.
- Verified with `hdiutil` on the real DMG (mounts `local, nobrowse`, not removable) and added a unit test in `test/updater_ui_test.dart` (10/10 passing).

---

## 7. Hardcoded Tray Version Label (Queued for `v1.50.127+`)

- User spotted `Lux 1.41.0` in a Windows system tray menu during remote support.
- Found hardcoded `MenuItem(key: 'lux', label: 'Lux 1.41.0', disabled: true)` in `lib/tray.dart` (the only hardcoded version string left in `lib/`).
- Fixed in `lux` `716ebcc` to resolve the real app version via `getAppVersionString()` (cached) and tracked in `docs/NEXT_RELEASE_TODO.md`.

---

## 8. VM Automation & Tooling Lessons Learned

Several environment quirks slowed down initial VM verification and are documented here to save time in future sessions:
- **`prlctl exec` hangs on very long command-line arguments** (e.g., multi-KB `-EncodedCommand` strings or long inline Python scripts) and when child processes inherit stdout/stderr pipes:
  - *Workaround:* Keep `prlctl exec` invocations short, drop `.py` test scripts into `\\Mac\Home\...` and invoke `python "\\Mac\Home\..."`, and launch GUI apps via `explorer.exe`.
- **PowerShell 5.1 traps:** `Set-Content -Encoding UTF8` writes a UTF-8 BOM that breaks Go `json.Unmarshal` (use Python UTF-8 or `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))`), and `-EncodedCommand` emits CLIXML progress noise on stderr unless `$ProgressPreference = 'SilentlyContinue'` is prepended.
- **WinINET System Proxy vs Python `urllib`:** When Lux enables the Windows system proxy, Python's default `urllib.request.urlopen("http://127.0.0.1:8000/...")` tries to route loopback API calls through `127.0.0.1:1090` and hangs — always build an explicit `urllib.request.build_opener(urllib.request.ProxyHandler({}))` for Core API calls.
- **Screenshots of sleeping/HiDPI VM displays:** `prlctl capture` captures black frames when the VM display powers off; Win32 `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` on `FLUTTER_RUNNER_WIN32_WINDOW` captures the live Lux window directly even when the display is off.

---

## Commit Index

### `itun2socks-clean` (`rebuild/clean-base`)
- `7fed286` — `fix(voip): bidirectional Fake-IP UDP NAT, STUN direct-UDP auto-probe for WFP fallback, and gVisor mixed stack`
- `f6a228c` — `feat(windows): add LuxCoreService native Windows service supervisor and per-user SID registry support`
- `75d173a` — `fix(windows): unmap raw IPv4 UDP replies from dual-stack sockets & harden UWP loopback`
- `a32befc` — `fix(pac): resolve single-label WPAD hosts via direct LAN DNS fallback on Windows`

### `lux` (`rebuild/clean-base`)
- `de569b2` — `release (beta): 1.50.121`
- `8396530` — `fix(windows): live UAC elevation on mode switch and wait for UAC before ping`
- `5b6516e` — `release (beta): 1.50.122`
- `750f7d1` — `feat(windows): one-time LuxCoreService install for zero-UAC Mixed/TUN restarts`
- `afd6586` — `release (beta): 1.50.123`
- `4aaf41c` — `feat(windows): elevate once via LuxCoreService for all modes with graceful UAC fallback & banner`
- `f561a48` — `release (beta): 1.50.124`
- `85a29c2` — `release (beta): 1.50.125`
- `bad5d91` — `fix(macos): mount update DMG at private temp mountpoint to avoid removable-volume TCC prompt`
- `2ecab72` — `release (beta): 1.50.126`
- `716ebcc` — `fix(tray): display actual app version instead of hardcoded 1.41.0` *(queued for `v1.50.127+`)*
