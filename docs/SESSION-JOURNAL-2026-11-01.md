# Session Journal — 2026-11-01 — Proxy-chooser redesign + beta 1.50.86 release

## Summary

Redesigned the Lux proxy-chooser page ("Option B" from an HTML prototype) to fix a
selection bug, added a labeled **Trust** button for cert-error proxies, then shipped the
result as **beta 1.50.86** (macOS + Windows). The release script's Windows step wedged on
a Parallels `prlctl exec` hiccup after the build had already succeeded; recovered by
completing the packaging/upload steps manually. Pushed to GitHub and republished the
download page (including a stale `<title>` fix).

Branch: `rebuild/clean-base` · Remote: `github.com/miguelAngelo1999/lux`
Author identity for all commits: **miguelAngelo1999** (per workspace steering
`.kiro/steering/git-identity.md`).

---

## 1. Proxy-chooser redesign (Option B)

### The bug
In the proxy list, clicking a radio button did NOT select the proxy — only clicking the
dead-space gaps worked. Architect-confirmed root cause: **hit-target layering**, not
RadioGroup wiring. The old `RadioListTile`'s `title` held a test-chip `GestureDetector`
and the `ProxyItemActionMenu` `IconButton`, which absorbed taps, so the select surface
was only the gaps between them.

### The fix (Option B — user-chosen over Option A via an HTML prototype)
Whole-row `InkWell.onTap` → `onSelect(id)` drives selection. The leading `Radio` is a
visual indicator only; trailing controls (result chip, Test button, ⋯ menu) are bounded
siblings that no longer steal the select tap. The ambiguous combined test-chip was split
into a separate labeled **Test** button plus an explicit result chip.

New `TestState` enum drives the result chip:
`untested` (hidden) / `testing` (spinner) / `reachable` (`123 ms`, green) /
`unreachable` (red) / `certError` (`Trust?`, amber, tap opens cert dialog) /
`notApplicable` (`PAC — n/a` for PAC-only entries).
certError no longer auto-opens the cert dialog — the user taps deliberately.

Files changed (all in `/Users/virgoh/lux-clean`):
- `lib/widget/proxy_list_item.dart` — rewrote the widget: added `TestState` enum,
  `selected` + `onSelect` params, `_isPacOnly` getter, `_resultChip()` helper; rewrote
  `build()` as Semantics → Material → InkWell → Stack(accent bar + Row). Removed the old
  `int? _delay`, `bool _testing`, `Color _delayColor(int)`.
- `lib/widget/proxy_list_card.dart` — added `onSelect`/`selectedId`, forwarded with
  `selected: widget.selectedId == item.id`.
- `lib/pages/proxies_page.dart` — passes `onSelect: handleSelectProxy,
  selectedId: proxyListGroup.selectedId` inside the `RadioGroup<String>`.

Commit: `c6fe804` fix(ui): redesign proxy chooser with whole-row select + explicit Test button

### Follow-up: explicit Trust button (user request "but no emoji")
Added a labeled **Trust** `OutlinedButton` (amber `0xFFE0A31E`, no icon/emoji) that
appears next to the Test button ONLY when `_state == TestState.certError`. It calls
`_promptCertTrust()` — the same cert-trust flow as the "Trust?" result chip — so the fix
action is discoverable without relying on tapping the chip.

Commit: `86bf4b0` feat(ui): add explicit Trust button for cert-error proxies

### Verification
`flutter analyze` on the 3 files: clean (only 4 PRE-EXISTING `proxies_page.dart` warnings
remain — lines 671/819/835/855 — none introduced by this work). Fixed the one warning I
did introduce: `unnecessary_brace_in_string_interps` at line 241 (`'${_latencyMs} ms'` →
`'$_latencyMs ms'`).

---

## 2. Release: beta 1.50.86 (macOS + Windows)

Ran `bash scripts/release_all.sh patch beta` (1.50.85 → 1.50.86).

### What went right
- macOS universal DMG built + verified: `dist/Lux-1.50.86-macOS-universal.dmg` (36 MB).
- Windows core (`lux_core.exe`) built on the Parallels VM, hash
  `f9866934c73954d458e86b5d7be9fb7ab69f3ca8a2e1c1024411010da5ef1630`.
- Windows Flutter app built fresh on the VM: `lux.exe` at 10:57 (AFTER a clean
  `flutter pub get --offline` wrote `.flutter-plugins-dependencies` at 10:55 and the old
  exe was deleted) — confirming it is NOT a stale binary.

### The incident — `prlctl exec` wedge (NOT a build failure)
The release script captures the VM Flutter build via a command substitution
(`FLUTTER_OUT=$(win_ps_script ...)`), so nothing streams until it returns. The terminal
sat at `CHECKSUM_SYNCED` for ~15 min. Diagnosis:
- Mac-side `prlctl exec ... build_flutter.ps1` (PID 67536) was alive but never returning;
  earlier Windows output showed `PrlJob_GetResult: Invalid argument` — a Parallels
  exec-channel hiccup.
- On the VM: NO active `dart`/`flutter`/`MSBuild`/`cl.exe` processes; the one live
  `powershell.exe` (PID 18580) had **StartTime Oct 31 2:20 PM** — a leftover from
  yesterday, unrelated to this run.
- `lux.exe` (10:57) was newer than `.flutter-plugins-dependencies` (10:55:59) → genuine
  fresh build. **The build succeeded; only the Mac-side exec return was wedged.**

### False alarm checked and dismissed
Noticed `windowsAmd64Checksum = ""` in both local and VM `lib/core/checksum.dart` and
briefly suspected a broken build. Read the file: the empty value is **intentional** —
`verifyCoreBinary()` does `if (Platform.isWindows) return;` (installer guarantees
integrity; a Dart-level check caused "checksum mismatch" crashes because the installer
can't kill the SYSTEM-owned lux_core.exe). So the empty checksum is correct and the
script's `WIN_HASH` regex (which can't match an empty `""`) being a no-op is harmless.

### Manual recovery (completed the remaining release steps by hand)
Killed the wedged `release_all.sh` + `build_flutter.ps1` processes, then ran the rest with
bounded `prlctl exec` calls:
1. **VC++ runtime bundle** → copied msvcp140/vcruntime140/vcruntime140_1 (+optional) into
   the Release folder from `...BuildTools\VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT`.
   → `VCRT_OK`.
2. **ISS prep** — verified Source references `runner\Release`, patched
   `#define MyAppVersion "1.50.86"` / `OutputBaseFilename` / `OutputDir`, confirmed
   auto-kill logic present (`KillLux` + `InitializeSetup`). No prompt directives
   (AppMutex/CloseApplications) needed removing. → `ISS_SRC_OK`, `ISS_KILL_OK`.
3. **ISCC** compile → "Successful compile (24.5 s)", installer in `C:\lux-build\dist2\`
   `lux-1.50.86-setup.exe` (27,664,110 bytes).
4. **Copy to Mac** — `copy` over `\\Mac\Home` hit the `PrlJob_GetResult: Invalid argument`
   wedge again; **robocopy single-file** succeeded. Renamed to
   `dist/Lux-1.50.86-Windows-x64-Setup.exe` (27,664,110 bytes — matches the VM).
5. **Uploads** (via python3.11 to avoid the 3.14 OpenSSL/corp-CA issue):
   - `publish_appcast.py 1.50.86 <dmg> --channel beta` → macOS entry updated, Windows
     entry preserved. DMG sha256 `3cd1d05f51c8c749...`
   - `publish_appcast_windows.py 1.50.86 <exe> --channel beta` → Windows entry updated,
     macOS entry preserved. installer sha256 `01e09fdaa2984321...`

### Verification (live appcasts on Drive)
```
LIVE BETA    mac=1.50.86  win=1.50.86     ← both updated
LIVE STABLE  mac=1.50.76  win=1.50.76     ← untouched
```
Commit: `354c6ee` release (beta): 1.50.86  (pubspec.yaml + appcast-beta.json)

---

## 3. Push + download page

- **Push**: `rebuild/clean-base` → GitHub `d5b8ef7..354c6ee` (slow through the corp proxy,
  ~2 min; first attempt timed out at 180s but the retry with `--progress` completed).
- **Download page** (`scripts/release-page/index.html`, here.now slug
  `bright-mustard-qghz`, account `lux`, URL https://download.lux.here.now):
  - Bumped beta section to **v1.50.86**, fixed macOS-beta size 43 MB → 36 MB.
    Beta Drive IDs are permanent (`1eNi0j...` mac, `1M-ZD53...` win) and overwritten
    in-place by the uploader, so the links already point at 1.50.86.
  - Fixed the stale `<title>` from `Lux 1.50.63` → `Lux — Download` (a static label that
    won't go stale again).
  - Republished to here.now (state: live) and verified the live title + beta version.

Commits: `23d3adb` docs(web): bump beta to 1.50.86 ; `e304237` docs(web): fix stale page title

---

## Changes / artifacts (reproduce or reverse)

| Item | Value |
|------|-------|
| Version | 1.50.85 → 1.50.86 (beta) |
| macOS DMG | `dist/Lux-1.50.86-macOS-universal.dmg`, 36 MB, sha256 `3cd1d05f51c8c749...` |
| Windows EXE | `dist/Lux-1.50.86-Windows-x64-Setup.exe`, 27,664,110 B, sha256 `01e09fdaa2984321...` |
| Beta appcast Drive ID | `1pvAmSjnhkf7tJbWetNj_hiNbjRhNPkyj` |
| macOS beta DMG Drive ID | `1eNi0j3mwEtpBQJmHmvg-AVn1vzaSbP8x` |
| Windows beta EXE Drive ID | `1M-ZD53ltBLX8KzpexH_qSGj5Rzz7Q5LU` |
| Commits | c6fe804, 86bf4b0, 354c6ee, 23d3adb, e304237 |

Rollback: re-run `publish_appcast.py` / `publish_appcast_windows.py` with the previous
1.50.85 artifacts to revert the beta appcast; stable (1.50.76) was never touched.

---

## Pending / side effects

- `appcast.json` (stable) had a PRE-EXISTING uncommitted local change syncing it from a
  stale 1.50.63 to the already-live 1.50.76. It matches what is live. Left **unstaged** to
  keep commits scoped to this beta release. Someone should commit it separately.
- The download page's main (stable) header still shows a version label (`v1.50.85`) that
  does not match live stable (1.50.76). Not touched this session — the stable download
  buttons go through the Cloudflare worker, so the label is cosmetic. Worth reconciling.
- Other untracked scratch dirs under `scripts/` (cf-worker, local-pac, revision-proxy,
  release-page/.herenow, apps_script_revision_proxy.js) were left untouched.

---

## Key learnings / patterns

1. **`prlctl exec` can wedge AFTER the VM step succeeds.** The symptom is a hung command
   substitution with `PrlJob_GetResult: Invalid argument` in the output. Before assuming a
   build failure, verify on the VM: (a) no active dart/flutter/MSBuild processes, (b) the
   output artifact (`lux.exe`) timestamp is newer than `.flutter-plugins-dependencies`,
   (c) any lingering powershell is from the current run (check `StartTime`). If the
   artifact is fresh, the build is good — kill the wedged Mac-side process and finish the
   remaining steps by hand.
2. **SMB `copy` from the VM to `\\Mac\Home` is the flaky step.** `robocopy` a single file
   is more robust than `cmd /c copy` across the Parallels SMB share.
3. **`windowsAmd64Checksum = ""` is intentional**, not a broken build. Windows skips the
   Dart checksum check (`if (Platform.isWindows) return;`); the installer guarantees
   integrity. Do not "fix" the empty value.
4. **The release script captures the VM Flutter build in a command substitution**, so it
   streams nothing until done — silence at `CHECKSUM_SYNCED` for several minutes is normal,
   but >10 min warrants the VM-side liveness check above.
5. Commits in this workspace are authored as **miguelAngelo1999** (NOT nimish.coelho — that
   identity is only for the Congregatio proxy-infra repos).
