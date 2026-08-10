# Windows build prompt

Paste the block below to an agent on the Windows machine.

Facts it encodes, verified on macOS 2026-08-10:

- `lux` and `itun2socks` are both on `rebuild/clean-base`; `lux-client` is on
  `feat/proxy-password-security-clean`
- `api/routes/dist-ui` is gitignored but `api/routes/routes.go:104` has
  `//go:embed dist-ui`, so a fresh clone will not compile until the web dashboard
  is built and copied in
- `verifyCoreBinary()` runs on every launch on Windows and throws when
  `windowsAmd64Checksum` does not match the shipped exe, so the core never starts
- the committed constant is `bcf719f712216f736a573ad1f088fd43525401ed63883dfaaf0cad93d2a2c492`,
  produced by a `go1.26.4` cross-compile; a different Go toolchain will produce a
  different digest
- `with_gvisor` must be omitted on Windows, which uses wintun
- target version is `1.50.4`

---

```text
Build Lux 1.50.4 for Windows x64 from source. Work in C:\lux-build.

Repos and branches — these exact branches, do not use main or feat/native-ui:

  lux         https://github.com/miguelAngelo1999/lux.git          branch rebuild/clean-base
  itun2socks  https://github.com/miguelAngelo1999/itun2socks.git   branch rebuild/clean-base
  lux-client  https://github.com/miguelAngelo1999/lux-client.git   branch feat/proxy-password-security-clean

Prerequisites: Go 1.25+, Node 18+, Flutter 3.44 with windows desktop enabled,
Visual Studio 2022 with the "Desktop development with C++" workload.
Run `flutter config --enable-windows-desktop` if it has not been enabled.

STEP 1 — clone all three at the branches above.

  git clone -b rebuild/clean-base https://github.com/miguelAngelo1999/lux.git
  git clone -b rebuild/clean-base https://github.com/miguelAngelo1999/itun2socks.git
  git clone -b feat/proxy-password-security-clean https://github.com/miguelAngelo1999/lux-client.git

Confirm each is on the branch you expect with `git rev-parse --abbrev-ref HEAD`
before continuing. If any clone landed on a different branch, stop and report.

STEP 2 — build the web dashboard and embed it. This is NOT optional.
api/routes/dist-ui is gitignored, and api/routes/routes.go has a //go:embed
dist-ui directive, so the Go build fails with "pattern dist-ui: no matching files
found" until this directory exists.

  cd lux-client
  npm install --legacy-peer-deps
  npx vite build

Strip the crossorigin attributes, which break the embedded WebView:
  powershell -Command "(Get-Content dist/index.html) -replace ' crossorigin','' | Set-Content dist/index.html"

Copy the output into the Go module:
  cd ..\itun2socks
  if (Test-Path api\routes\dist-ui) { Remove-Item -Recurse -Force api\routes\dist-ui }
  Copy-Item -Recurse ..\lux-client\dist api\routes\dist-ui

Verify api\routes\dist-ui\index.html exists before continuing.

STEP 3 — build the core. Do NOT pass -tags="with_gvisor"; that is macOS only and
Windows uses the wintun driver.

  cd itun2socks
  $env:CGO_ENABLED = "0"
  go build -ldflags="-s -w" -trimpath -o ..\lux\assets\bin\lux_core.exe .

STEP 4 — reconcile the startup checksum. THIS IS THE STEP THAT SILENTLY BREAKS
THE APP IF SKIPPED. lib/core/checksum.dart carries a sha256 of lux_core.exe, and
process_manager.dart calls verifyCoreBinary() on every launch on Windows. On a
mismatch it throws and the core never starts, with no obvious symptom beyond the
app failing to connect.

  cd ..\lux
  (Get-FileHash "assets\bin\lux_core.exe" -Algorithm SHA256).Hash.ToLower()

Compare that to windowsAmd64Checksum in lib\core\checksum.dart, currently:
  bcf719f712216f736a573ad1f088fd43525401ed63883dfaaf0cad93d2a2c492

If they match, change nothing and continue.

If they differ, it is because your Go toolchain differs from the one that produced
the committed value. That is expected and fine. Set the constant to YOUR hash:
edit lib\core\checksum.dart and replace the windowsAmd64Checksum value with the
hash you just computed. Leave the darwin constants alone. Report both hashes in
your final summary so the difference is on record.

STEP 5 — build the app.

  flutter pub get
  flutter build windows --release

Output: build\windows\x64\runner\Release\

STEP 6 — verify before packaging.

  a. build\windows\x64\runner\Release\lux.exe exists
  b. assets\bin\lux_core.exe is present under the Release folder's
     data\flutter_assets\assets\bin\
  c. the hash of that shipped copy still equals windowsAmd64Checksum
  d. launch lux.exe, accept the UAC prompt, and confirm the core starts: the app
     should report a running state rather than a checksum or elevation error.
     lux_core needs administrator rights to create the TUN adapter.
  e. check the log at
     %APPDATA%\com.github.igoogolx.lux\1.0\logs\core.log for lines containing
     "fail to" or "checksum"

STEP 7 — package. Include every file from the Release folder. lux_core.exe
requires elevation, so set the UAC manifest level to requireAdministrator. Use
Inno Setup or MSIX.

Report back with: the branch and commit of each repo, the core exe hash, whether
you had to change checksum.dart, and the result of each check in step 6. If any
step fails, stop there and report the exact error rather than working around it.
```

---

## If you would rather not rebuild the core on Windows

The checksum reconciliation in step 4 exists only because the Go toolchain
differs between machines. Copying `assets/bin/lux_core.exe` from this Mac removes
that variable, and lets the Windows agent skip steps 2 through 4 entirely, since
the dashboard is already embedded in that binary.

```bash
# on macOS, produces the exe and syncs the constant
bash scripts/build_core_windows.sh
# then hand assets/bin/lux_core.exe to the Windows machine, to be placed at
# lux\assets\bin\lux_core.exe before flutter build windows --release
```
