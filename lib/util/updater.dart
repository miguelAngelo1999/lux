import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';

import '../const/const.dart';
import '../core/core_config.dart';
import 'app_log.dart';

/// Result of an update check.
class UpdateInfo {
  final String latestVersion;
  final String currentVersion;
  final String notes;
  final String macOSUrl;
  final String windowsUrl;
  final bool hasUpdate;

  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.notes,
    required this.macOSUrl,
    required this.windowsUrl,
    required this.hasUpdate,
  });
}

/// Fetches the appcast.json from Google Drive and compares versions.
/// [proxyPort] is the local Lux proxy port (default 1090) — needed because
/// Dart's HttpClient doesn't pick up the system proxy in TUN/Mixed mode.
Future<UpdateInfo?> checkForUpdate({int proxyPort = 1090}) async {
  HttpClient? client;
  try {
    final pkg = await PackageInfo.fromPlatform();
    final current = pkg.version;

    // Use custom appcast URL if set in prefs, otherwise fall back to default
    final customUrl = await readCustomAppcastUrl();
    final baseUrl = (customUrl != null && customUrl.isNotEmpty) ? customUrl : appcastUrl;

    // Use Dart's HttpClient directly with proxy + SSL bypass
    client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;
    client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort; DIRECT';

    // Add cache-busting only for GDrive URLs (query param approach)
    final cacheBust = baseUrl.contains('?') ? '&_t=' : '?_t=';
    final fetchUrl = baseUrl.contains('drive.usercontent.google.com')
        ? Uri.parse('$baseUrl${cacheBust}${DateTime.now().millisecondsSinceEpoch}')
        : Uri.parse(baseUrl);

    final request = await client.getUrl(fetchUrl);
    request.followRedirects = true;
    request.headers.set('Cache-Control', 'no-cache, no-store');
    request.headers.set('Pragma', 'no-cache');
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response.transform(const SystemEncoding().decoder).join();

    if (response.statusCode != 200) {
      debugPrint('[Updater] HTTP ${response.statusCode}');
      // Try without proxy (DIRECT) as fallback
      client.findProxy = (_) => 'DIRECT';
      final req2 = await client.getUrl(Uri.parse(baseUrl));
      req2.followRedirects = true;
      final resp2 = await req2.close().timeout(const Duration(seconds: 10));
      if (resp2.statusCode != 200) return null;
      final body2 = await resp2.transform(const SystemEncoding().decoder).join();
      return _parseAppcast(body2, current);
    }
    appLog('UPDATE', 'appcast fetched status=${response.statusCode} body=${body.substring(0, body.length.clamp(0, 200))}');
    return _parseAppcast(body, current);
  } catch (e) {
    debugPrint('[Updater] check failed: $e');
    return null;
  } finally {
    client?.close();
  }
}

UpdateInfo? _parseAppcast(String body, String current) {
  try {
    final data = Map<String, dynamic>.from(
        const JsonDecoder().convert(body) as Map);

    final latest = (data['version'] as String?) ?? '';
    if (latest.isEmpty) return null;

    final macos   = (data['macOS']   as Map?)?.cast<String, dynamic>() ?? {};
    final windows = (data['windows'] as Map?)?.cast<String, dynamic>() ?? {};

    final macOSUrl   = (macos['url']   as String?) ?? '';
    final windowsUrl = (windows['url'] as String?) ?? '';

    // Only flag an update if this platform actually has a download URL.
    // A Windows-only release leaves macOS.url empty — don't notify Mac users.
    final platformUrl = Platform.isMacOS ? macOSUrl : windowsUrl;
    final hasUpdate = platformUrl.isNotEmpty &&
        Version.parse(latest).compareTo(Version.parse(current)) > 0;
    appLog('UPDATE', 'appcast parsed latest=$latest current=$current '
        'platformUrl=${platformUrl.isNotEmpty} hasUpdate=$hasUpdate');

    return UpdateInfo(
      latestVersion:  latest,
      currentVersion: current,
      notes:          (data['notes'] as String?) ?? '',
      macOSUrl:       macOSUrl,
      windowsUrl:     windowsUrl,
      hasUpdate:      hasUpdate,
    );
  } catch (e) {
    debugPrint('[Updater] parse failed: $e');
    return null;
  }
}

/// Shows the in-app update dialog. Returns true if user accepted.
Future<bool> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _UpdateDialog(info: info),
  );
  return result == true;
}

/// Downloads the DMG/EXE to a temp file and opens it.
Future<void> downloadAndInstall(
  BuildContext context,
  UpdateInfo info, {
  void Function(double progress)? onProgress,
  void Function(String status)? onStatusChange,
}) async {
  final url = Platform.isMacOS ? info.macOSUrl : info.windowsUrl;
  if (url.isEmpty) {
    await launchUrl(Uri.parse(releasesPageUrl));
    return;
  }

  try {
    final tmp  = await getTemporaryDirectory();
    final ext  = Platform.isMacOS ? '.dmg' : '.exe';
    final file = File('${tmp.path}/Lux-${info.latestVersion}$ext');

    // Delete any previously cached DMG for this version to force a fresh download.
    // Stale cached files cause the wrong app version to be installed.
    if (await file.exists()) {
      await file.delete();
      appLog('UPDATE', 'deleted stale cached DMG: ${file.path}');
    }

    debugPrint('[Updater] downloading $url → ${file.path}');
    appLog('UPDATE', 'download started url=$url dest=${file.path}');

    // Use lux's own proxy port for the download — it has corporate proxy
    // credentials and handles SSL. Fall back to DIRECT if not running.
    // We intentionally do NOT read HTTP_PROXY/HTTPS_PROXY env vars because
    // on some machines they contain placeholder values (e.g. "seu_ip:porta")
    // that cause "Invalid proxy configuration" errors.
    final client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;
    // Try lux proxy first (127.0.0.1:1090), fall back to DIRECT
    client.findProxy = (_) => 'PROXY 127.0.0.1:1090; DIRECT';

    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    final response = await request.close().timeout(const Duration(minutes: 5));

    appLog('UPDATE', 'download response status=${response.statusCode} '
        'contentType=${response.headers.contentType} '
        'contentLength=${response.contentLength}');

    if (response.statusCode != 200) {
      appLog('UPDATE', 'download failed — HTTP ${response.statusCode}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed — server returned ${response.statusCode}'),
            action: SnackBarAction(
              label: 'Open in browser',
              onPressed: () => launchUrl(Uri.parse(releasesPageUrl)),
            ),
          ),
        );
      }
      return;
    }

    // Ensure the temp directory exists before opening the file for writing.
    // getTemporaryDirectory() returns a path that may not exist yet on macOS.
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    final total = response.contentLength;
    int received = 0;
    int lastLoggedPct = -1;
    final sink = file.openWrite();

    // Use a Completer so we can detect hangs — if no bytes arrive for 60s, abort.
    final completer = Completer<void>();
    Timer? stallTimer;

    void resetStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(const Duration(seconds: 60), () {
        if (!completer.isCompleted) {
          appLog('UPDATE', 'download stalled — no data for 60s, aborting');
          completer.completeError('Download stalled');
        }
      });
    }

    resetStallTimer(); // start the stall watchdog

    final sub = response.listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        resetStallTimer(); // got data — reset the watchdog
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
        // Log every 10% to help diagnose future hangs
        if (total > 0) {
          final pct = (received * 100 ~/ total);
          if (pct >= lastLoggedPct + 10) {
            lastLoggedPct = pct;
            appLog('UPDATE', 'download progress $pct% (${received}/${total}B)');
          }
        }
      },
      onDone: () {
        stallTimer?.cancel();
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        stallTimer?.cancel();
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );

    try {
      await completer.future;
    } catch (e) {
      await sub.cancel();
      await sink.close();
      appLog('UPDATE', 'download stream error: $e');
      rethrow;
    }

    await sink.flush();
    await sink.close();
    client.close();

    final fileSize = await file.length();
    appLog('UPDATE', 'download complete size=${fileSize}B file=${file.path}');
    debugPrint('[Updater] downloaded ${fileSize}B to ${file.path}');

    // Sanity check — reject HTML pages (< 1MB means we got an error page)
    if (fileSize < 1024 * 1024) {
      final peek = await file.openRead(0, 500).fold<List<int>>([], (a, b) => a..addAll(b));
      final text = String.fromCharCodes(peek.take(200));
      appLog('UPDATE', 'file too small (${fileSize}B) — likely HTML. Preview: ${text.substring(0, text.length.clamp(0, 100))}');
      debugPrint('[Updater] file too small, probably HTML: $text');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Download failed — received ${fileSize}B (expected ~37MB). '
              'Check your internet connection.',
            ),
            action: SnackBarAction(
              label: 'Open in browser',
              onPressed: () => launchUrl(Uri.parse(releasesPageUrl)),
            ),
            duration: const Duration(seconds: 10),
          ),
        );
      }
      return;
    }

    if (Platform.isMacOS) {
      onStatusChange?.call('Mounting DMG…');
      // Remove quarantine attribute added by macOS to internet-downloaded files.
      await Process.run('xattr', ['-d', 'com.apple.quarantine', file.path]);
      appLog('UPDATE', 'quarantine removed, mounting DMG');

      // Detach ALL previously mounted Lux volumes to avoid stale mounts.
      final volDir = Directory('/Volumes');
      if (await volDir.exists()) {
        final luxVols = volDir.listSync().whereType<Directory>().where(
          (d) => d.path == '/Volumes/Lux' || d.path.startsWith('/Volumes/Lux ')
        ).toList();
        for (final vol in luxVols) {
          appLog('UPDATE', 'detaching stale Lux volume: ${vol.path}');
          await Process.run('hdiutil', ['detach', vol.path, '-quiet', '-force']);
        }
      }

      // Mount the DMG
      final mountResult = await Process.run('hdiutil', [
        'attach', file.path,
        '-nobrowse', '-noverify', '-noautoopen',
      ]);
      if (mountResult.exitCode != 0) {
        appLog('UPDATE', 'hdiutil attach failed: ${mountResult.stderr}');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not mount DMG: ${mountResult.stderr}')),
          );
        }
        return;
      }

      // Find Lux.app in the mounted volume
      final volumesResult = await Process.run('find', [
        '/Volumes', '-maxdepth', '2', '-name', 'Lux.app', '-type', 'd'
      ]);
      final appPath = volumesResult.stdout.toString().trim().split('\n').firstWhere(
        (l) => l.endsWith('Lux.app'),
        orElse: () => '',
      );

      if (appPath.isEmpty) {
        appLog('UPDATE', 'Lux.app not found in mounted DMG');
        await Process.run('hdiutil', ['detach', '-quiet', '-force', '/Volumes']);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Lux.app not found in downloaded DMG')),
          );
        }
        return;
      }

      final mountPoint = appPath.substring(0, appPath.lastIndexOf('/'));
      appLog('UPDATE', 'found app at $appPath — installing as user');

      // ── User-space install ────────────────────────────────────────────────
      // /Applications/Lux.app is owned by the user — no root needed to replace it.
      // We install directly from Dart in the user's GUI session, then relaunch
      // from the same session. This is the key fix for post-update relaunch on Sequoia.

      onStatusChange?.call('Installing…');

      // Kill lux_core before replacing the bundle (wrapper script would be overwritten)
      await Process.run('sudo', ['-n', 'pkill', '-9', '-f', 'lux_core_real'],
          runInShell: false);
      await Future.delayed(const Duration(seconds: 1));

      const dest = '/Applications/Lux.app';
      final destNew = '$dest.new';

      // Atomic install: ditto to .new, then mv
      await Process.run('rm', ['-rf', destNew]);
      final dittoResult = await Process.run('ditto', [appPath, destNew]);
      if (dittoResult.exitCode != 0) {
        appLog('UPDATE', 'ditto failed: ${dittoResult.stderr}');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Install failed: ${dittoResult.stderr}')),
          );
        }
        await Process.run('hdiutil', ['detach', mountPoint, '-quiet', '-force']);
        return;
      }

      await Process.run('rm', ['-rf', dest]);
      await Process.run('mv', [destNew, dest]);
      appLog('UPDATE', 'app installed to $dest');

      // Detach DMG
      await Process.run('hdiutil', ['detach', mountPoint, '-quiet', '-force']);

      // ── Elevation setup (root needed, uses existing NOPASSWD) ────────────
      // Set up lux_core_real setuid + sudoers — uses the existing helper script
      const helperDir = '/Library/PrivilegedHelperTools/com.github.igoogolx.lux';
      final elevScript = File('$helperDir/lux_updater.sh');

      // Write a minimal elevation-only script (no install, no relaunch)
      final elevScriptContent = _buildElevationScript();
      try {
        await elevScript.writeAsString(elevScriptContent);
        await Process.run('chmod', ['+x', elevScript.path]);
        appLog('UPDATE', 'elevation script written, running via sudo -n');
        await Process.run('sudo', ['-n', '/bin/bash', elevScript.path],
            runInShell: false);
        appLog('UPDATE', 'elevation setup complete');
      } catch (e) {
        appLog('UPDATE', 'elevation setup failed (non-fatal): $e');
        // Non-fatal — lux_core will prompt for elevation on next start
      }

      // ── Relaunch from user GUI session ────────────────────────────────────
      // We are still running as the user in the GUI session — open works here.
      // Kill the current process first so open actually launches a new instance.
      onStatusChange?.call('Restarting Lux…');
      appLog('UPDATE', 'relaunching Lux from user session');
      // Use a detached shell script that waits for THIS process to die before opening
      final myPid = pid; // current Dart process PID
      final relaunchScript = File('/tmp/lux_reopen.sh');
      await relaunchScript.writeAsString(
        '#!/bin/bash\n'
        '# Wait for old Lux process ($myPid) to fully exit\n'
        'for i in \$(seq 1 20); do\n'
        '  kill -0 $myPid 2>/dev/null || break\n'
        '  sleep 0.5\n'
        'done\n'
        'sleep 1\n'
        '/usr/bin/open -a /Applications/Lux.app\n'
        'rm -f /tmp/lux_reopen.sh\n',
      );
      await Process.run('chmod', ['+x', relaunchScript.path]);
      await Process.start('bash', [relaunchScript.path],
          mode: ProcessStartMode.detached);
      await Future.delayed(const Duration(milliseconds: 300));
      exit(0);
    } else if (Platform.isWindows) {
      // Same pattern as macOS: write a standalone updater script, launch it
      // detached so it outlives this process, then exit lux.
      // The script waits for lux to fully die, then runs the installer.
      appLog('UPDATE', 'writing detached Windows updater script');

      final scriptPath = '${file.parent.path}\\lux_updater.bat';
      final script = _buildWindowsUpdaterScript(file.path);
      await File(scriptPath).writeAsString(script);

      appLog('UPDATE', 'launching detached updater script and exiting');

      // Launch via cmd /c start "" /b — fully detached, no window, outlives lux
      await Process.start(
        'cmd.exe',
        ['/c', 'start', '', '/b', 'cmd.exe', '/c', scriptPath],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );

      // Give script a moment to start, then exit
      await Future.delayed(const Duration(milliseconds: 500));
      appLog('UPDATE', 'exiting lux for updater');
      exit(0);
    }
  } catch (e) {
    appLog('UPDATE', 'download error: $e');
    debugPrint('[Updater] download failed: $e');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Update failed: $e'),
          action: SnackBarAction(
            label: 'Open in browser',
            onPressed: () => launchUrl(Uri.parse(releasesPageUrl)),
          ),
          duration: const Duration(seconds: 10),
        ),
      );
    }
  }
}

// ── Windows updater script ────────────────────────────────────────────────────

/// Builds a standalone Windows batch file that runs OUTSIDE the Lux process.
/// Flow: Lux writes script → launches detached → Lux exits →
///       script waits → stops lux_core → runs installer elevated (UAC) →
///       installer's ssPostInstall does schtasks /run to relaunch Lux.
String _buildWindowsUpdaterScript(String installerPath) {
  // Escape backslashes for the batch file
  final escaped = installerPath.replaceAll('/', '\\');
  // Single-quoted for PowerShell inside batch (avoids double-quote nesting issues)
  final psEscaped = escaped.replaceAll("'", "''");
  return '@echo off\r\n'
      'echo Lux updater started at %date% %time% > "%TEMP%\\lux_updater.log"\r\n'
      '\r\n'
      ':: Wait for lux.exe to fully exit (it exits after launching us)\r\n'
      ':wait_lux\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'tasklist /FI "IMAGENAME eq lux.exe" 2>nul | find /i "lux.exe" >nul\r\n'
      'if not errorlevel 1 goto wait_lux\r\n'
      'echo lux.exe exited >> "%TEMP%\\lux_updater.log"\r\n'
      '\r\n'
      ':: Kill lux_core HERE (in user context) before elevating.\r\n'
      ':: Once we elevate for the installer, Stop-Process can\'t reach user processes.\r\n'
      'schtasks /end /tn LuxApp >nul 2>&1\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'taskkill /F /IM lux_core.exe /T >nul 2>&1\r\n'
      'taskkill /F /IM lux.exe /T >nul 2>&1\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'echo processes killed >> "%TEMP%\\lux_updater.log"\r\n'
      '\r\n'
      ':: Run installer elevated via PowerShell Start-Process -Verb RunAs.\r\n'
      ':: All lux processes are already dead so the installer can overwrite lux.exe.\r\n'
      ':: -Wait ensures this bat does not exit until installer finishes.\r\n'
      ':: The installer ssPostInstall does "schtasks /run /tn LuxApp" to relaunch Lux.\r\n'
      'echo Running installer: $escaped >> "%TEMP%\\lux_updater.log"\r\n'
      'powershell -NonInteractive -WindowStyle Hidden -Command '
      '"Start-Process -FilePath \'$psEscaped\' '
      '-ArgumentList \'/VERYSILENT\',\'/SUPPRESSMSGBOXES\',\'/NORESTART\' '
      '-Verb RunAs -Wait"\r\n'
      'echo Installer exited with code %errorlevel% >> "%TEMP%\\lux_updater.log"\r\n'
      '\r\n'
      ':: Clean up this script\r\n'
      'del "%~f0"\r\n';
}

// ── macOS install helpers ──────────────────────────────────────────────────────

/// Builds a minimal elevation-only script that sets up lux_core_real with
/// setuid root + NOPASSWD sudoers. No install, no relaunch — just elevation.
/// The install itself is now done in-process by Flutter as the user.
String _buildElevationScript() {
  return r'''
#!/bin/bash
exec >> /tmp/lux_elevation.log 2>&1
echo "Elevation setup started at $(date)"

DEST="/Applications/Lux.app"
BIN="$DEST/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL="${BIN}_real"
HELPER_DIR="/Library/PrivilegedHelperTools/com.github.igoogolx.lux"
USER_NAME=$(stat -f '%Su' /dev/console 2>/dev/null || echo "$SUDO_USER")

# Set up wrapper + setuid if not already done
if [ -f "$BIN" ] && ! grep -q "exec sudo" "$BIN" 2>/dev/null; then
  mv "$BIN" "$REAL"
  printf '#!/bin/bash\nexec sudo "%s" "$@"\n' "$REAL" > "$BIN"
  chmod 755 "$BIN"
fi
if [ -f "$REAL" ]; then
  chown root:wheel "$REAL"
  chmod 770 "$REAL"
  chmod u+s "$REAL"
fi

# Update sudoers
if [ -n "$USER_NAME" ] && [ -f "$REAL" ]; then
  mkdir -p "$HELPER_DIR"
  {
    echo "$USER_NAME ALL=(root) NOPASSWD: $REAL *"
    echo "$USER_NAME ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_proxy_apply.sh *"
    echo "$USER_NAME ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_proxy_clear.sh"
    echo "$USER_NAME ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_cert_install.sh"
    echo "$USER_NAME ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_network_reset.sh"
    echo "$USER_NAME ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_updater.sh"
  } > /etc/sudoers.d/lux_core
  chmod 0440 /etc/sudoers.d/lux_core
  visudo -c -f /etc/sudoers.d/lux_core 2>/dev/null || rm -f /etc/sudoers.d/lux_core
fi

echo "Elevation setup complete at $(date)"
''';
}

/// Builds a standalone installer script that runs independently of the Lux process.
/// It waits for Lux to exit, installs the new app, sets up elevation, and relaunches.
String _buildInstallerScript(String srcApp, String mountPoint) {
  return '''#!/bin/bash
# Lux external updater — runs after Lux exits
exec > /tmp/lux_updater.log 2>&1
echo "Updater started at \$(date)"

# Wait for Lux to fully exit
sleep 3
for i in \$(seq 1 10); do
  if ! pgrep -x Lux > /dev/null 2>&1; then
    break
  fi
  echo "Waiting for Lux to exit... attempt \$i"
  sleep 1
done

# Force kill if still running
pkill -9 -x lux_core_real 2>/dev/null || true
pkill -9 -x Lux 2>/dev/null || true
sleep 1

SRC="$srcApp"
DEST="/Applications/Lux.app"
BIN="\$DEST/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL="\${BIN}_real"

# Remove quarantine from source app before copying (prevents fcopyfile I/O errors)
xattr -cr "\$SRC" 2>/dev/null || true

# Install — atomic copy to prevent partial install if interrupted
# Use ditto (macOS-native) instead of cp -R — handles frameworks/symlinks correctly
echo "Copying new app from \$SRC to \$DEST.new..."
rm -rf "\$DEST.new"
ditto "\$SRC" "\$DEST.new"
if [ \$? -ne 0 ]; then
  echo "ERROR: ditto failed — aborting install, keeping old app"
  rm -rf "\$DEST.new"
  # Relaunch the existing app via one-shot LaunchAgent
  LOGGED_USER=\$(stat -f '%Su' /dev/console)
  LOGGED_UID=\$(id -u "\$LOGGED_USER" 2>/dev/null)
  echo "Relaunching existing Lux after failed update..."
  if [ -n "\$LOGGED_UID" ]; then
    PLIST="/Users/\$LOGGED_USER/Library/LaunchAgents/io.github.lux.relaunch.plist"
    sudo -u "\$LOGGED_USER" tee "\$PLIST" > /dev/null << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>io.github.lux.relaunch</string><key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>/Applications/Lux.app</string></array><key>RunAtLoad</key><true/></dict></plist>
PLIST_EOF
    launchctl asuser "\$LOGGED_UID" launchctl load -w "\$PLIST" 2>/dev/null || true
    sleep 2
    launchctl asuser "\$LOGGED_UID" launchctl unload "\$PLIST" 2>/dev/null || true
    sudo -u "\$LOGGED_USER" rm -f "\$PLIST" 2>/dev/null || true
  fi
  exit 1
fi
echo "Copy complete — swapping in new app..."
rm -rf "\$DEST"
mv "\$DEST.new" "\$DEST"
echo "Swap complete"

# Set up elevation wrapper
if [ -f "\$BIN" ] && ! grep -q "exec sudo" "\$BIN" 2>/dev/null; then
  mv "\$BIN" "\$REAL"
  printf '#!/bin/bash\\nexec sudo "%s" "\$@"\\n' "\$REAL" > "\$BIN"
  chmod 755 "\$BIN"
fi
if [ -f "\$REAL" ]; then
  chown root:wheel "\$REAL"
  chmod 770 "\$REAL"
  chmod u+s "\$REAL"
fi

# Update sudoers — full NOPASSWD entries (lux_core_real + proxy/cert scripts)
SUDO_FILE="/etc/sudoers.d/lux_core"
HELPER_DIR="/Library/PrivilegedHelperTools/com.github.igoogolx.lux"
USER_NAME=\$(stat -f '%Su' /dev/console 2>/dev/null || echo "\$SUDO_USER")
if [ -n "\$USER_NAME" ] && [ -f "\$REAL" ]; then
  mkdir -p "\$HELPER_DIR"
  # User-owned so Flutter can write scripts there without root
  chown "\$USER_NAME":staff "\$HELPER_DIR"
  chmod 755 "\$HELPER_DIR"
  {
    echo "\$USER_NAME ALL=(root) NOPASSWD: \$REAL *"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash \$HELPER_DIR/lux_proxy_apply.sh *"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash \$HELPER_DIR/lux_proxy_clear.sh"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash \$HELPER_DIR/lux_cert_install.sh"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash \$HELPER_DIR/lux_network_reset.sh"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash \$HELPER_DIR/lux_updater.sh"
  } > "\$SUDO_FILE"
  chmod 0440 "\$SUDO_FILE"
  visudo -c -f "\$SUDO_FILE" 2>/dev/null || rm -f "\$SUDO_FILE"
fi

# Detach the DMG
echo "Detaching DMG..."
hdiutil detach "$mountPoint" -quiet -force 2>/dev/null || true

# Relaunch Lux via a one-shot LaunchAgent — only reliable method from root on Sequoia
echo "Relaunching Lux..."
LOGGED_USER=\$(stat -f '%Su' /dev/console)
LOGGED_UID=\$(id -u "\$LOGGED_USER" 2>/dev/null)
if [ -n "\$LOGGED_UID" ]; then
  PLIST="/Users/\$LOGGED_USER/Library/LaunchAgents/io.github.lux.relaunch.plist"
  sudo -u "\$LOGGED_USER" tee "\$PLIST" > /dev/null << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.lux.relaunch</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>/Applications/Lux.app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST_EOF
  launchctl asuser "\$LOGGED_UID" launchctl load -w "\$PLIST" 2>/dev/null || true
  sleep 3
  launchctl asuser "\$LOGGED_UID" launchctl unload "\$PLIST" 2>/dev/null || true
  sudo -u "\$LOGGED_USER" rm -f "\$PLIST" 2>/dev/null || true
fi

echo "Update complete at \$(date)"
rm -f /tmp/lux_updater.sh
''';
}

// ── Dialog widget ──────────────────────────────────────────────────────────────

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null = not downloading, 0-1 = progress
  bool _done = false;
  String _statusText = '';

  Future<void> _download() async {
    setState(() => _progress = 0);
    await downloadAndInstall(
      context,
      widget.info,
      onProgress: (p) => setState(() => _progress = p),
      onStatusChange: (s) { if (mounted) setState(() => _statusText = s); },
    );
    // Only close dialog if we actually got to exit(0) — if download failed,
    // the snackbar is shown and we stay open so user can retry or dismiss.
    // downloadAndInstall only returns (without calling exit) on failure.
    if (mounted) {
      setState(() { _progress = null; }); // reset so buttons reappear
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.system_update_alt, size: 20),
        const SizedBox(width: 8),
        Text('Lux ${info.latestVersion} available'),
      ]),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current: ${info.currentVersion}  →  Latest: ${info.latestVersion}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'What\'s new',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(info.notes, style: const TextStyle(fontSize: 12)),
              ),
            ],
            if (_progress != null) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _done ? 1.0 : _progress),
              const SizedBox(height: 4),
              Text(
                _statusText.isNotEmpty
                    ? _statusText
                    : 'Downloading… ${((_progress ?? 0) * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),
      actions: _progress != null
          ? null // hide buttons while downloading
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Later'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop(false);
                  await launchUrl(Uri.parse(releasesPageUrl));
                },
                child: const Text('Open in browser'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.download, size: 16),
                label: const Text('Download & Install'),
                onPressed: _download,
              ),
            ],
    );
  }
}
