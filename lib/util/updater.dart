import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';

import '../const/const.dart';
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
  try {
    final pkg = await PackageInfo.fromPlatform();
    final current = pkg.version;

    // Use Dart's HttpClient directly with proxy + SSL bypass
    final client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;
    client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort; DIRECT';

    final request = await client.getUrl(Uri.parse(appcastUrl));
    request.followRedirects = true;
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response.transform(const SystemEncoding().decoder).join();

    if (response.statusCode != 200) {
      debugPrint('[Updater] HTTP ${response.statusCode}');
      // Try without proxy (DIRECT) as fallback
      client.findProxy = (_) => 'DIRECT';
      final req2 = await client.getUrl(Uri.parse(appcastUrl));
      req2.followRedirects = true;
      final resp2 = await req2.close().timeout(const Duration(seconds: 10));
      if (resp2.statusCode != 200) return null;
      final body2 = await resp2.transform(const SystemEncoding().decoder).join();
      return _parseAppcast(body2, current);
    }
    client.close();
    appLog('UPDATE', 'appcast fetched status=${response.statusCode} body=${body.substring(0, body.length.clamp(0, 200))}');
    return _parseAppcast(body, current);
  } catch (e) {
    debugPrint('[Updater] check failed: $e');
    return null;
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

    debugPrint('[Updater] downloading $url → ${file.path}');
    appLog('UPDATE', 'download started url=$url dest=${file.path}');

    // Use DIRECT for the DMG download — the system proxy (set by lux_core via
    // networksetup) handles authentication transparently. Routing through
    // Lux's own 1090 port adds an extra SSL interception layer that causes
    // GDrive to return 403. HttpClient with findProxy=null uses the OS proxy.
    final client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;
    // Do NOT set findProxy — let Dart use the system proxy (set by networksetup)
    // which already has corp proxy credentials. This is how browsers download.

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
      appLog('UPDATE', 'quarantine removed, mounting DMG and installing');

      // Detach any existing mount of this DMG file (avoids "Resource busy").
      // hdiutil info -plist gives structured XML; parse the image-path lines
      // to find the right disk, then detach by device node.
      final infoResult = await Process.run('hdiutil', ['info']);
      final infoLines = infoResult.stdout.toString().split('\n');
      String? pendingImagePath;
      for (final rawLine in infoLines) {
        final line = rawLine.trim();
        if (line.startsWith('image-path')) {
          pendingImagePath = line.contains(':') ? line.split(':').sublist(1).join(':').trim() : null;
        } else if (pendingImagePath != null && line.startsWith('/dev/')) {
          // This device belongs to the last seen image-path.
          // If that image path is our DMG file, detach it.
          if (pendingImagePath == file.path) {
            final dev = line.split(RegExp(r'\s+')).first.trim();
            appLog('UPDATE', 'detaching previous mount of DMG: $dev');
            await Process.run('hdiutil', ['detach', dev, '-quiet', '-force']);
          }
          pendingImagePath = null;
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

      // Find the mounted volume containing Lux.app
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

      // Derive the volume mount point (parent dir of Lux.app inside /Volumes)
      final mountPoint = appPath.substring(0, appPath.lastIndexOf('/'));
      appLog('UPDATE', 'found app at $appPath mount=$mountPoint — installing');

      // Write a standalone installer script that runs OUTSIDE this process.
      // Flow: Lux writes script → launches it detached → Lux exits →
      //       script waits → kills lux_core → installs → relaunches Lux.
      final installerScript = File('/tmp/lux_updater.sh');
      await installerScript.writeAsString(_buildInstallerScript(appPath, mountPoint));
      await Process.run('chmod', ['+x', installerScript.path]);

      onStatusChange?.call('Installing… Lux will restart');
      appLog('UPDATE', 'launching external installer and exiting');

      // Launch installer detached — it will outlive this process.
      // Use osascript to get admin rights and run the script backgrounded.
      // The script itself handles waiting for Lux to exit before installing.
      final sudoTest = await Process.run('sudo', ['-n', 'true']);
      if (sudoTest.exitCode == 0) {
        // NOPASSWD works — start directly with sudo, backgrounded
        await Process.run('bash', ['-c',
          'sudo bash ${installerScript.path} &'
        ]);
      } else {
        // Need password/Touch ID — osascript runs it backgrounded via &
        final osaResult = await Process.run('/usr/bin/osascript', ['-e',
          'do shell script "bash \'${installerScript.path}\' &" '
          'with administrator privileges',
        ]);
        if (osaResult.exitCode != 0) {
          appLog('UPDATE', 'osascript failed: ${osaResult.stderr}');
          await Process.run('hdiutil', ['detach', mountPoint, '-quiet', '-force']);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(
                osaResult.stderr.toString().contains('cancel')
                    ? 'Update cancelled.'
                    : 'Install failed: ${osaResult.stderr}',
              )),
            );
          }
          return;
        }
      }

      // Give the script a moment to start, then exit gracefully
      await Future.delayed(const Duration(seconds: 1));
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
///       script waits → stops lux_core → runs installer → installer relaunches Lux.
String _buildWindowsUpdaterScript(String installerPath) {
  // Escape backslashes for the batch file
  final escaped = installerPath.replaceAll('/', '\\');
  return '@echo off\r\n'
      'echo Lux updater started at %date% %time% > "%TEMP%\\lux_updater.log"\r\n'
      '\r\n'
      ':: Wait for lux.exe to fully exit (it exits after launching us)\r\n'
      ':wait_lux\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'tasklist /FI "IMAGENAME eq lux.exe" 2>nul | find /i "lux.exe" >nul\r\n'
      'if not errorlevel 1 goto wait_lux\r\n'
      '\r\n'
      ':: Also stop lux_core via scheduled task (handles elevated processes)\r\n'
      'schtasks /end /tn LuxApp >nul 2>&1\r\n'
      'timeout /t 2 /nobreak >nul\r\n'
      'taskkill /F /IM lux_core.exe /T >nul 2>&1\r\n'
      'timeout /t 1 /nobreak >nul\r\n'
      '\r\n'
      ':: Run installer silently — it will relaunch lux on finish\r\n'
      'echo Running installer: $escaped >> "%TEMP%\\lux_updater.log"\r\n'
      '"$escaped" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART\r\n'
      'echo Installer exited with code %errorlevel% >> "%TEMP%\\lux_updater.log"\r\n'
      '\r\n'
      ':: Clean up this script\r\n'
      'del "%~f0"\r\n';
}

// ── macOS install helpers ──────────────────────────────────────────────────────

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

# Install — atomic copy to prevent partial install if interrupted
# Copy to .new first, then swap — if cp is killed midway, old app survives
echo "Copying new app from \$SRC to \$DEST.new..."
rm -rf "\$DEST.new"
cp -R "\$SRC" "\$DEST.new"
if [ \$? -ne 0 ]; then
  echo "ERROR: cp failed — aborting, keeping old app"
  rm -rf "\$DEST.new"
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

# Update sudoers — preserve all four NOPASSWD entries (same as initial setup)
SUDO_FILE="/etc/sudoers.d/lux_core"
USER_NAME=\$(stat -f '%Su' /dev/console 2>/dev/null || echo "\$SUDO_USER")
if [ -n "\$USER_NAME" ] && [ -f "\$REAL" ]; then
  {
    echo "\$USER_NAME ALL=(root) NOPASSWD: \$REAL *"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /tmp/lux_proxy_apply.sh"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /tmp/lux_proxy_clear.sh"
    echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /tmp/lux_cert_install.sh"
  } > "\$SUDO_FILE"
  chmod 0440 "\$SUDO_FILE"
  visudo -c -f "\$SUDO_FILE" 2>/dev/null || rm -f "\$SUDO_FILE"
fi

# Detach the DMG
echo "Detaching DMG..."
hdiutil detach "$mountPoint" -quiet -force 2>/dev/null || true

# Relaunch Lux as the logged-in user (not as root)
echo "Relaunching Lux..."
LOGGED_USER=\$(stat -f '%Su' /dev/console)
sudo -u "\$LOGGED_USER" open /Applications/Lux.app

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
