# Windows Build Guide — Lux

This document covers everything needed to build, install, and package Lux on
this specific Windows ARM64 machine (Snapdragon). Written for build agents.

---

## Machine Context

| Item | Value |
|------|-------|
| OS | Windows 11 ARM64 (Snapdragon) |
| Architecture | ARM64 host, building x64 targets (cross-compile) |
| Flutter SDK | `C:\tmp\flutter` (Flutter 3.41.5 / Dart 3.11.3) |
| Go | `C:\Program Files\Go\bin` (Go 1.25) |
| VS Build Tools | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |
| Windows SDK | `C:\Program Files (x86)\Windows Kits\10\` (version 10.0.22621.0) |
| Internet | HTTP proxy on `127.0.0.1:1090` (lux itself), SSL-intercepting |

---

## Repository Layout

| Repo | Local Path | Remote |
|------|-----------|--------|
| Flutter app (`lux`) | `C:\Users\virgoh\lux` | `fork` → `github.com/miguelAngelo1999/lux` |
| Go backend (`itun2socks`) | `C:\Users\virgoh\itun2socks` | `origin` → `github.com/miguelAngelo1999/itun2socks` |

### Branch Map

| Branch | Contains |
|--------|---------|
| `feat/proxy-autodetect` | **Current work** — Windows proxy autodetect + SSL bump + cert installer |
| `feat/ssl-inspection` | SSL inspection MITM proxy feature |
| `personal/all-features` | macOS all-features (merged base) |
| `feat/proxy-password-security-clean` | Password security (Windows LogonUser verify) |

---

## CRITICAL: Environment Setup (Every Session)

**Always run this before any build command:**

```powershell
$env:Path = "C:\tmp\flutter\bin;C:\tmp\flutter\bin\cache\dart-sdk\bin;C:\Program Files\Go\bin;C:\Program Files\Git\cmd;C:\Program Files\PowerShell\7;C:\WINDOWS\system32;C:\WINDOWS;C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64;$env:Path"
$env:HTTP_PROXY  = 'http://127.0.0.1:1090'
$env:HTTPS_PROXY = 'http://127.0.0.1:1090'
```

`C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64` **must** be on
PATH for `rc.exe` to be found by the linker during CMake.

---

## The ONLY Correct Build + Install Sequence

Every change to lux_core (Go) requires **all 5 steps in order**. No shortcuts.

```
Step 1: Build lux_core → temp file
  cd C:\Users\virgoh\itun2socks
  go build -tags with_gvisor -o "C:\Users\virgoh\lux\assets\bin\lux_core_new.exe" .
  Move-Item assets\bin\lux_core_new.exe assets\bin\lux_core.exe -Force

Step 2: Hash the new binary IMMEDIATELY (before any other build)
  $hash = (Get-FileHash "assets\bin\lux_core.exe" -Algorithm SHA256).Hash.ToLower()
  Write-Host "Hash: $hash"

Step 3: Update checksum.dart with that exact hash
  # Edit lib/core/checksum.dart:
  # const windowsAmd64Checksum = "<hash>";

Step 4: Verify hash matches before building Flutter
  $bin = (Get-FileHash "assets\bin\lux_core.exe" -Algorithm SHA256).Hash.ToLower()
  $src = ((Select-String "windowsAmd64Checksum" "lib\core\checksum.dart")[0]).Line -replace '.*"([^"]+)".*','$1'
  Write-Host "Match: $($bin -eq $src)"   # MUST be True before proceeding

Step 5: Build Flutter (AFTER checksum.dart is updated)
  # See "Flutter Build Command" section below

Step 6: Stop lux, install ALL files together as a matched set
  # See "Install" section below
```

### Why Order Matters

- **Mistake A**: Rebuild lux_core twice before Flutter build → hash mismatch
- **Mistake B**: Forget Flutter rebuild after updating checksum.dart → old app.so
- **Mistake C**: Copy lux_core.exe without copying matching lux.exe + data/ → snapshot mismatch
- **Mistake D**: Copy lux.exe + data/ without ALL *.dll files → "Wrong full snapshot version"

---

## Building lux_core (Go)

```powershell
cd C:\Users\virgoh\itun2socks
$env:Path = "C:\Program Files\Go\bin;$env:Path"
$env:HTTP_PROXY = 'http://127.0.0.1:1090'
$env:HTTPS_PROXY = 'http://127.0.0.1:1090'

# Build to temp name — never overwrite running binary directly
go build -tags with_gvisor -o "C:\Users\virgoh\lux\assets\bin\lux_core_new.exe" .
Move-Item "C:\Users\virgoh\lux\assets\bin\lux_core_new.exe" `
          "C:\Users\virgoh\lux\assets\bin\lux_core.exe" -Force
```

**Note on tags**: `with_gvisor` is REQUIRED on Windows for TUN mode. The
build agent prompt that says "do NOT use gvisor on Windows" is WRONG for this
machine. Always use `-tags with_gvisor`.

---

## Flutter Build Command

**Must use `cmd /c`** — PowerShell's PATH handling causes issues with Flutter:

```powershell
cmd /c "set PATH=C:\tmp\flutter\bin;C:\tmp\flutter\bin\cache\dart-sdk\bin;C:\Program Files\Git\cmd;C:\Program Files\PowerShell\7;C:\WINDOWS\system32;C:\WINDOWS;C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64 & set HTTP_PROXY=http://127.0.0.1:1090 & set HTTPS_PROXY=http://127.0.0.1:1090 & cd C:\Users\virgoh\lux & flutter build windows --release --no-pub 2>&1"
```

Use `--no-pub` to skip dependency resolution (avoid network calls). Run
`flutter pub get --offline` first if `.dart_tool/package_config.json` is missing.

### If Build Fails with cmake cache error

The most common cause is a stale cmake/dart build cache:

```powershell
# Kill lingering processes first
Get-Process dart,cmake,ninja,cl -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2

# Remove caches
Remove-Item "C:\Users\virgoh\lux\build" -Recurse -Force
Remove-Item "C:\Users\virgoh\lux\.dart_tool\flutter_build" -Recurse -Force -EA SilentlyContinue

# Then rebuild
```

### If flutter pub get hangs (network issue)

```powershell
# Use offline mode — packages are already cached
cmd /c "... & flutter pub get --offline 2>&1"
```

---

## Install

**Stop lux first — you will briefly lose internet connection:**

```powershell
Stop-Process -Name lux,lux_core -Force -EA SilentlyContinue
Start-Sleep 2

$src = "C:\Users\virgoh\lux\build\windows\x64\runner\Release"
$dst = "$env:LOCALAPPDATA\Programs\lux"

# Copy lux.exe + all DLLs
Copy-Item "$src\lux.exe" "$dst\lux.exe" -Force
Get-ChildItem "$src" -Filter "*.dll" | ForEach-Object { Copy-Item $_.FullName "$dst\$($_.Name)" -Force }

# Delete stale data/ first (MUST — stale data causes checksum mismatch)
Remove-Item "$dst\data" -Recurse -Force -EA SilentlyContinue
Copy-Item "$src\data" "$dst\data" -Recurse -Force

# flutter build does NOT create assets\bin — create manually
New-Item -ItemType Directory -Path "$dst\data\flutter_assets\assets\bin" -Force | Out-Null
Copy-Item "C:\Users\virgoh\lux\assets\bin\lux_core.exe" `
          "$dst\data\flutter_assets\assets\bin\lux_core.exe" -Force

# Verify before launching
$core = (Get-FileHash "$dst\data\flutter_assets\assets\bin\lux_core.exe" -Algorithm SHA256).Hash.ToLower()
$exp  = ((Select-String "windowsAmd64Checksum" "C:\Users\virgoh\lux\lib\core\checksum.dart")[0]).Line -replace '.*"([^"]+)".*','$1'
Write-Host "Match: $($core -eq $exp)"   # Must be True

Start-Process "$dst\lux.exe"
```

---

## ARM64 Cross-Compilation Patches

This machine is ARM64 but builds x64. Several patches are required and must
be in place before building Flutter.

### 1. Flutter tool patch — `-T host=ARM64`

Flutter must pass `-T host=ARM64` to CMake. Check if it's applied:

```powershell
Select-String "host=ARM64" "C:\tmp\flutter\packages\flutter_tools\lib\src\windows\build_windows.dart"
```

If missing, re-apply:

```powershell
$file = "C:\tmp\flutter\packages\flutter_tools\lib\src\windows\build_windows.dart"
$lines = [System.Collections.ArrayList](Get-Content $file)
$idx = ($lines | Select-String "getCmakeWindowsArch").LineNumber - 1
$lines.Insert($idx + 1, "      '-T',")
$lines.Insert($idx + 2, "      'host=ARM64',")
Set-Content $file -Value $lines
Remove-Item "C:\tmp\flutter\bin\cache\flutter_tools.snapshot" -Force -EA SilentlyContinue
$rev = git -C "C:\tmp\flutter" rev-parse HEAD
Set-Content "C:\tmp\flutter\bin\cache\flutter_tools.stamp" -Value "`"$rev`":" -NoNewline
```

### 2. MSBuild SDK path injection

File must exist (requires admin):

```
C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Microsoft\VC\v170\ImportBefore\Default\lux_sdk_paths.props
```

Check: `Test-Path "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Microsoft\VC\v170\ImportBefore\Default\lux_sdk_paths.props"`

If missing, recreate (run as admin):

```powershell
$dir = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Microsoft\VC\v170\ImportBefore\Default"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Set-Content "$dir\lux_sdk_paths.props" @'
<Project>
  <PropertyGroup>
    <WindowsSDK_LibraryPath_x64 Condition="'$(WindowsSDK_LibraryPath_x64)' == ''">C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0\ucrt\x64</WindowsSDK_LibraryPath_x64>
    <WindowsSDKLibVersion Condition="'$(WindowsSDKLibVersion)' == ''">10.0.22621.0\</WindowsSDKLibVersion>
    <WindowsTargetPlatformVersion Condition="'$(WindowsTargetPlatformVersion)' == ''">10.0.22621.0</WindowsTargetPlatformVersion>
    <WindowsSdkVerBinPath Condition="'$(WindowsSdkVerBinPath)' == ''">C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\</WindowsSdkVerBinPath>
    <RCToolPath Condition="'$(RCToolPath)' == ''">C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\</RCToolPath>
  </PropertyGroup>
</Project>
'@
```

Also create the ImportAfter rc.exe props (run as admin):

```powershell
$dir2 = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Microsoft\VC\v170\Platforms\x64\PlatformToolsets\v143\ImportAfter"
New-Item -ItemType Directory -Path $dir2 -Force | Out-Null
Set-Content "$dir2\lux_sdk_rc.props" @'
<Project>
  <PropertyGroup>
    <ExecutablePath>$(ExecutablePath);C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64</ExecutablePath>
    <IncludePath>$(IncludePath);C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\um;C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\ucrt;C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\shared</IncludePath>
    <LibraryPath>$(LibraryPath);C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0\um\x64;C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0\ucrt\x64</LibraryPath>
  </PropertyGroup>
</Project>
'@
```

### 3. Registry SDK detection (run as admin)

```powershell
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name "InstallationFolder" -Value "C:\Program Files (x86)\Windows Kits\10\" -Type String
Set-ItemProperty -Path $regPath -Name "ProductVersion" -Value "10.0.22621" -Type String
```

---

## Building the Installer

Prerequisites:
- Official lux installer at `C:\tmp\lux-official.exe`
- InnoSetup 6 at `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`
- Chinese language file at `C:\Users\virgoh\lux\windows\packaging\exe\ChineseSimplified.isl`

```powershell
# Stage release files
$src     = "C:\Users\virgoh\lux\build\windows\x64\runner\Release"
$staging = "C:\Users\virgoh\lux\dist\1.40.2\lux-1.40.2-windows-setup_exe"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Copy-Item -Path "$src\*" -Destination $staging -Recurse -Force
New-Item -ItemType Directory -Path "$staging\data\flutter_assets\assets\bin" -Force | Out-Null
Copy-Item "C:\Users\virgoh\lux\assets\bin\lux_core.exe" "$staging\data\flutter_assets\assets\bin\lux_core.exe" -Force

# Build installer
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "C:\Users\virgoh\lux\dist\1.40.2\lux-1.40.2-windows-setup_exe.iss"
# Output: C:\Users\virgoh\lux\dist\1.40.2\lux-1.40.3-windows-setup.exe
```

---

## Uploading to Google Drive

Credentials at `Y:\vcf\credentials.json` and `Y:\vcf\gdrive_token.pickle`
(network drive Y: must be mounted).

```powershell
$env:HTTP_PROXY = 'http://127.0.0.1:1090'
$env:HTTPS_PROXY = 'http://127.0.0.1:1090'
python "C:\Users\virgoh\lux\upload_installer.py"
```

---

## Troubleshooting

### "Checksum of core binary is not matched"

```
Expect [<old_hash>] get <new_hash>
```

Cause: `app.so` has an old checksum baked in.
Fix:
1. Check `app.so` has the new hash: `Select-String "windowsAmd64Checksum" lib\core\checksum.dart`
2. If wrong: update checksum.dart and rebuild Flutter
3. If right but still failing: the installed `app.so` is stale — reinstall

### "Wrong full snapshot version"

```
expected 'XXXXXXXX' found 'YYYYYYYY'
```

Cause: `lux.exe` and `app.so` are from different Flutter SDK versions.
Fix: Touch `windows\runner\main.cpp` to force lux.exe relink, then rebuild Flutter and reinstall.

### "No CMAKE_CXX_COMPILER could be found"

The `-T host=ARM64` patch was lost (Flutter tool snapshot regenerated).
Fix: Re-apply the patch (Section: ARM64 Cross-Compilation Patches → step 1).

### "kernel32.lib not found" / "cannot run rc.exe"

MSBuild props files are missing.
Fix: Re-create ImportBefore/ImportAfter props files (Section: ARM64 patches → steps 2+3).

### Build fails with "Permission denied" on .obj files

Background cmake/dart process is holding file locks.
Fix:
```powershell
Get-Process dart,cmake,ninja,cl -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2
Remove-Item "build" -Recurse -Force
```

### Go build fails with TLS/certificate errors

The corporate proxy intercepts HTTPS. Set:
```powershell
$env:GONOSUMCHECK = "*"
$env:GONOSUMDB    = "*"
$env:GOINSECURE   = "*"
$env:HTTP_PROXY   = 'http://127.0.0.1:1090'
$env:HTTPS_PROXY  = 'http://127.0.0.1:1090'
```

### flutter pub get hangs (resolving dependencies)

The proxy blocks pub.dev or the TLS cert is not trusted.
Fix: Use offline mode after deleting `.dart_tool`:
```powershell
Remove-Item ".dart_tool" -Recurse -Force
cmd /c "set PATH=... & flutter pub get --offline"
```

### App launches but shows spinner forever

lux_core is not starting. Check:
1. Checksum match (step 4 above)
2. `C:\Users\virgoh\lux\core_err.txt` for error messages
3. Run lux_core.exe manually from terminal to see error output

### Log/Connections pages empty

WebSocket not connecting. Verify `await channel.ready` is present before
`.stream.listen()` in all 5 files:
- `lib/pages/log_page.dart`
- `lib/pages/connections_page.dart`
- `lib/widget/app_bottom_bar.dart`
- `lib/widget/app_header_bar.dart`
- `lib/home.dart`

### "open rules/proxy_all: file does not exist"

lux_core starts but can't connect. The rules/ dir has stubs but `proxy_all`
is missing. Fix:
```powershell
# Create the file in itun2socks
New-Item -Path "C:\Users\virgoh\itun2socks\internal\cfg\distribution\rule_engine\rules\proxy_all" -Force
Set-Content "C:\Users\virgoh\itun2socks\internal\cfg\distribution\rule_engine\rules\proxy_all" "DOMAIN-REGEX,.*,PROXY"
# Then rebuild lux_core and follow full 5-step sequence
```

---

## Building for Other Branches (for another agent)

When building `personal/all-features` or `feat/proxy-password-security-clean`
for distribution as a zip (not installer), follow these steps:

### 1. Switch branches

```powershell
cd C:\Users\virgoh\lux
git fetch fork
git checkout fork/personal/all-features -b personal/all-features-build

cd C:\Users\virgoh\itun2socks
git fetch origin
git checkout origin/personal/all-features -b personal/all-features-build
```

### 2. Build lux_core (same as always — with gvisor tag)

```powershell
cd C:\Users\virgoh\itun2socks
go build -tags with_gvisor -o "C:\Users\virgoh\lux\assets\bin\lux_core_new.exe" .
Move-Item "C:\Users\virgoh\lux\assets\bin\lux_core_new.exe" `
          "C:\Users\virgoh\lux\assets\bin\lux_core.exe" -Force
```

### 3. Update checksum.dart + build Flutter + verify

(Same 5-step sequence as above)

### 4. Package as zip (not installer)

```powershell
$src     = "C:\Users\virgoh\lux\build\windows\x64\runner\Release"
$zipDir  = "C:\tmp\Lux-1.41.0-all-features-Windows-x64"
New-Item -ItemType Directory $zipDir -Force | Out-Null
Copy-Item "$src\*" $zipDir -Recurse -Force
New-Item -ItemType Directory "$zipDir\data\flutter_assets\assets\bin" -Force | Out-Null
Copy-Item "C:\Users\virgoh\lux\assets\bin\lux_core.exe" "$zipDir\data\flutter_assets\assets\bin\lux_core.exe" -Force
Compress-Archive -Path "$zipDir\*" -DestinationPath "C:\tmp\Lux-1.41.0-all-features-Windows-x64.zip" -Force
```

### 5. For security-clean version

```powershell
cd C:\Users\virgoh\lux
git checkout fork/feat/proxy-password-security-clean -b security-clean-build
# itun2socks stays on personal/all-features (same Go backend)
# Rebuild Flutter only (lux_core is the same binary)
# Package as Lux-1.41.0-security-clean-Windows-x64.zip
```

---

## Quick Verification Checklist Before Any Install

```powershell
# Run this before installing — all three must match
$binHash  = (Get-FileHash "assets\bin\lux_core.exe" -Algorithm SHA256).Hash.ToLower()
$srcHash  = ((Select-String "windowsAmd64Checksum" "lib\core\checksum.dart")[0]).Line -replace '.*"([^"]+)".*','$1'
$appSoAge = (Get-Item "build\windows\x64\runner\Release\data\app.so").LastWriteTime

Write-Host "lux_core hash:  $binHash"
Write-Host "checksum.dart:  $srcHash"
Write-Host "MATCH:          $($binHash -eq $srcHash)"   # Must be True
Write-Host "app.so built:   $appSoAge"                  # Must be recent
```
