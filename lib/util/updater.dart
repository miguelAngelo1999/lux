import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';

import '../const/const.dart';

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
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final pkg = await PackageInfo.fromPlatform();
    final current = pkg.version;

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      // bypass proxy for update check — goes direct
      headers: {'Cache-Control': 'no-cache'},
    ));

    final resp = await dio.get<Map<String, dynamic>>(appcastUrl);
    final data = resp.data!;

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
    debugPrint('[Updater] check failed: $e');
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

    final dio = Dio();
    await dio.download(
      url,
      file.path,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );

    if (Platform.isMacOS) {
      // Open the DMG — user drags to Applications
      await Process.run('open', [file.path]);
    } else {
      // Run the installer silently on Windows
      await Process.run(file.path, ['/SILENT']);
    }
  } catch (e) {
    debugPrint('[Updater] download failed: $e');
    // Fall back to browser
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
