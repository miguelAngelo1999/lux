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
      await launchUrl(Uri.parse(releasesPageUrl));
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
      await launchUrl(Uri.parse(releasesPageUrl));
      return;
    }

    if (Platform.isMacOS) {
      // Remove quarantine attribute added by macOS to internet-downloaded files.
      await Process.run('xattr', ['-d', 'com.apple.quarantine', file.path]);
      appLog('UPDATE', 'quarantine removed, mounting DMG and installing');

      // Mount the DMG
      final mountResult = await Process.run('hdiutil', [
        'attach', file.path,
        '-nobrowse', '-quiet', '-noverify',
      ]);
      if (mountResult.exitCode != 0) {
        appLog('UPDATE', 'hdiutil attach failed: ${mountResult.stderr}');
        await launchUrl(Uri.parse(releasesPageUrl));
        return;
      }

      // Find the mounted volume containing Lux.app
      final volumesResult = await Process.run('find', [
        '/Volumes', '-maxdepth', '2', '-name', 'Lux.app', '-type', 'd'
      ]);
      final appPath = volumesResult.stdout.toString().trim().split('\n').firstWhere(
        (l) => l.contains('Lux.app'),
        orElse: () => '',
      );

      if (appPath.isEmpty) {
        appLog('UPDATE', 'Lux.app not found in mounted DMG');
        await launchUrl(Uri.parse(releasesPageUrl));
        return;
      }
      appLog('UPDATE', 'found app at $appPath — copying to /Applications');

      // Copy to /Applications (overwrites existing)
      final copyResult = await Process.run('cp', ['-R', appPath, '/Applications/Lux.app']);
      if (copyResult.exitCode != 0) {
        // Try with osascript for admin rights
        appLog('UPDATE', 'cp failed (${copyResult.exitCode}), trying with admin rights');
        await Process.run('/usr/bin/osascript', [
          '-e',
          'do shell script "cp -R \\"$appPath\\" /Applications/Lux.app" with administrator privileges',
        ]);
      }
      appLog('UPDATE', 'copy complete — detaching DMG and relaunching');

      // Detach the DMG
      await Process.run('hdiutil', ['detach', appPath.replaceAll('/Lux.app', ''), '-quiet']);

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
    await launchUrl(Uri.parse(releasesPageUrl));
  }
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
