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

    final hasUpdate =
        Version.parse(latest).compareTo(Version.parse(current)) > 0;

    final macos   = (data['macOS']   as Map?)?.cast<String, dynamic>() ?? {};
    final windows = (data['windows'] as Map?)?.cast<String, dynamic>() ?? {};

    return UpdateInfo(
      latestVersion:  latest,
      currentVersion: current,
      notes:          (data['notes'] as String?) ?? '',
      macOSUrl:       (macos['url']   as String?) ?? '',
      windowsUrl:     (windows['url'] as String?) ?? '',
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

    final client = HttpClient();
    client.badCertificateCallback = (_, __, ___) => true;
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

    final total = response.contentLength;
    int received = 0;
    final sink = file.openWrite();
    await response.listen((chunk) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0 && onProgress != null) {
        onProgress(received / total);
      }
    }).asFuture();
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

      // Install script:
      //  1. rm -rf existing /Applications/Lux.app  (avoids cp-into-directory issue)
      //  2. cp -R from DMG
      //  3. set up elevation wrapper + sudoers (same as initial deploy)
      final installScript = _buildInstallScript(appPath);
      appLog('UPDATE', 'running install script');

      // Try sudo -n first (NOPASSWD already configured after first launch)
      final sudoResult = await Process.run(
        'sudo', ['-n', 'bash', '-c', installScript],
      );
      if (sudoResult.exitCode != 0) {
        // Fall back to osascript (Touch ID / password dialog)
        appLog('UPDATE', 'sudo -n failed (${sudoResult.exitCode}), using osascript');
        final osaResult = await Process.run('/usr/bin/osascript', [
          '-e',
          'do shell script ${_shellQuote(installScript)} with administrator privileges',
        ]);
        if (osaResult.exitCode != 0) {
          appLog('UPDATE', 'osascript install failed: ${osaResult.stderr}');
          // Clean up DMG and show error — don't silently open GitHub
          await Process.run('hdiutil', ['detach', mountPoint, '-quiet', '-force']);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text(
                'Install cancelled. Download is in your temp folder — you can install manually.',
              )),
            );
          }
          return;
        }
      }

      appLog('UPDATE', 'install complete — detaching DMG and relaunching');

      // Detach the DMG
      await Process.run('hdiutil', ['detach', mountPoint, '-quiet', '-force']);

      // Relaunch Lux from the newly installed version
      await Process.run('open', ['/Applications/Lux.app']);

      // Quit this instance
      exit(0);
    } else {
      await Process.run(file.path, ['/SILENT']);
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

// ── macOS install helpers ──────────────────────────────────────────────────────

/// Builds the bash install script that replaces /Applications/Lux.app cleanly
/// and sets up the elevation wrapper + sudoers entry (same as initial deploy).
String _buildInstallScript(String srcApp) {
  // srcApp = /Volumes/Lux 1.x.y/Lux.app
  return r'''
set -e
SRC="''' + srcApp + r'''"
DEST="/Applications/Lux.app"
BIN="$DEST/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL="${BIN}_real"

# Kill running instance before replacing
pkill -9 -x lux_core_real 2>/dev/null || true
pkill -9 -x Lux           2>/dev/null || true
sleep 1

# Remove old app (must rm first — cp -R copies INTO existing dir on macOS)
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# Set up elevation wrapper (idempotent — safe to run on every update)
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

# Update sudoers entry
SUDO_FILE="/etc/sudoers.d/lux_core"
USER_NAME=$(stat -f '%Su' /dev/console 2>/dev/null || echo "$SUDO_USER")
if [ -n "$USER_NAME" ] && [ -f "$REAL" ]; then
  echo "$USER_NAME ALL=(root) NOPASSWD: $REAL *" > "$SUDO_FILE"
  chmod 0440 "$SUDO_FILE"
  visudo -c -f "$SUDO_FILE" 2>/dev/null || rm -f "$SUDO_FILE"
fi
''';
}

/// Shell-quotes a string for use inside an osascript do shell script argument.
String _shellQuote(String s) {
  // Escape backslashes and double-quotes, then wrap in double quotes
  final escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
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

  Future<void> _download() async {
    setState(() => _progress = 0);
    await downloadAndInstall(
      context,
      widget.info,
      onProgress: (p) => setState(() => _progress = p),
    );
    setState(() { _progress = 1.0; _done = true; });
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) Navigator.of(context).pop(true);
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
                _done
                    ? 'Done — open the installer to complete'
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
