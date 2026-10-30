# Handoff: release Lux 1.50.85 (beta) for macOS and Windows

Written 2026-10-30. For the Kiro IDE agent. The previous agent could not run the build:
its shell is blocked from Xcode (`sandbox-exec: Operation not permitted`) and from the
Windows VM in Parallels. You can, so you run the release.

## State right now

- Repo: `/Users/virgoh/lux-clean`, branch `rebuild/clean-base`. Core repo: `/Users/virgoh/itun2socks-clean`.
- `pubspec.yaml` is `1.50.84+1`. 1.50.84 beta is already published (`f33025b`, `0794f09`).
  The next release bumps to **1.50.85**. Do not reuse 1.50.84.
- Channel: **beta only**. Never publish to stable.

## What 1.50.85 adds (all committed, none released yet)

lux-clean:
- `b6c09e3` macOS: also set `SSL_CERT_FILE` (same CA bundle) on connect, clear on disconnect.
  Fixes Antigravity "x509: certificate signed by unknown authority" (worked by hand with both vars set + app restart).
- `37b10cb` Checksum of `proxy_ca_bundle.pem` before/after connect; if it changed, notify
  "Certificates changed. Restart Node/Electron apps ...". Mac and Windows.
- `2399ac7` macOS now asks for notification permission at start (it never did, so no notification ever showed);
  adds an "update available" notification.
- `9784ad9` `scripts/release_all.sh`: copies `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`
  (+ optional `msvcp140_1`, `msvcp140_2`, `concrt140`) into the Windows Release folder before the installer is built.
  Fixes "lux.exe: MSVCP140.dll not found" on PCs without the VC++ Redistributable.
  Aborts the release if a required DLL is missing or the VM's `dist-setup.iss` does not reference `runner\Release`.
  Never run on the VM yet.

itun2socks-clean (already committed, check they are in the build):
- `23b815a` login keychain included in the Node CA bundle (macOS), bundle refreshed after install-cert.
- `ffa5133`, `5c40b6f`, `274edde`, `5ac1cfa` PAC fixes and `GET /proxies/{id}/pac-upstream`.

## Before you run the release

1. The macOS `lux_core` is **not rebuilt by `release_all.sh`** and `assets/bin/` is git-ignored.
   Rebuild it so it includes `23b815a`:
   ```
   cd /Users/virgoh/itun2socks-clean
   CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -trimpath -tags="with_gvisor" -o /tmp/lux_core_arm64 .
   CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -trimpath -tags="with_gvisor" -o /tmp/lux_core_amd64 .
   lipo -create -output /Users/virgoh/lux-clean/assets/bin/lux_core /tmp/lux_core_arm64 /tmp/lux_core_amd64
   file /Users/virgoh/lux-clean/assets/bin/lux_core   # must say 2 architectures
   ```
   The Windows core is rebuilt by the script inside the VM.
2. Do not use `flutter clean`.
3. The working tree has changes that are NOT yours. Do not stage, commit or revert them:
   `appcast.json` (edited by hand), `macos/Podfile.lock`, `macos/install.sh`, `scripts/release-page/index.html`,
   and untracked `scripts/apps_script_revision_proxy.js`, `scripts/cf-worker/`, `scripts/local-pac/`,
   `scripts/release-page/.herenow/`, `scripts/revision-proxy/`.
   Check how `release_all.sh` handles `appcast.json` before running; if it would overwrite those edits, stop and ask.

## Run

```
cd /Users/virgoh/lux-clean && bash scripts/release_all.sh patch beta
```

Run it once. If it fails half way, do **not** run it again blindly: a second run bumps to 1.50.86.
Read the error, fix the cause, and resume by hand or ask the user.

## Lines to look for in the Windows part of the output

- `FLUTTER_OK`
- `ISS_KILL_OK` (installer kills a running Lux by itself, no "please close Lux" prompt)
- `VCRT_SRC <path>` then `VCRT_OK`
- `ISS_SRC_OK`
- `ISCC_OK`

If you see `VCRT_MISSING ...`: the VM has no VC++ runtime DLLs where the script looks
(Visual Studio `VC\Redist\MSVC\...\x64\Microsoft.VC*.CRT`, else `C:\Windows\System32`). Install the
"Microsoft Visual C++ Redistributable x64" on the VM or fix the search path in `release_all.sh`. Do not skip the check.

If you see `ISS_SRC_MISSING`: the VM's `C:\lux-build\lux\dist-setup.iss` does not mention `runner\Release`.
Open that file, find its `[Files] Source:` line, and make the script check match it. Do not remove the guard.

Hard rules from earlier mistakes: the installer script must NOT contain `AppMutex=` or
`CloseApplications`. The script already enforces this.

## Verify after the release (required, never say "done" without it)

```
python3 - << 'EOF'
import json, urllib.request, ssl
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
u2 = "https://drive.usercontent.google.com/download?id=1pvAmSjnhkf7tJbWetNj_hiNbjRhNPkyj&export=download&confirm=t"
d2 = json.loads(urllib.request.urlopen(u2, context=ctx).read())
print(f"BETA    mac={d2['macOS'].get('version','MISSING')}  win={d2['windows'].get('version','MISSING')}")
EOF
```

Both must print `1.50.85`. Also check the Windows entry's URL differs from the macOS one
(known failure: Windows URL pointing at the macOS file id).

## Do not

- Do not publish to stable. Do not copy anything into `/Applications` yourself.
- Do not run `sudo`, `launchctl` changes or edit sudoers.
- Do not `git push` unless the user asks. Commit freely on this branch with explicit file names, no `git add -A`.
- Do not claim the fix works. Nothing here has been run in the app.

## What the user should test after installing (put this in your report)

macOS:
1. First launch shows "Lux would like to send you notifications". Click Allow.
2. Connect. If the CA bundle changed, a notification says to restart Node/Electron apps.
3. Quit and reopen Antigravity: it should sign in with no x509 error.
4. A proxy whose CA is not trusted yet shows the "Certificate not trusted" prompt on connect.

Windows:
1. Run the installer with Lux already running: it must close Lux by itself, with no prompt.
2. On a PC without the VC++ Redistributable (the one that showed "MSVCP140.dll not found"): `lux.exe` must start.

## Report back with

- Commands run and their last lines.
- The appcast check output.
- Anything that stopped or looked off, with the exact error text.
- Which of the test items above you could not do.
