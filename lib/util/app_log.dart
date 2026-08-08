/// Persistent blackbox event log for debugging Lux crashes and issues.
/// Writes timestamped events to a rotating log file alongside lux_core logs.
/// Max 500 lines — older entries are trimmed on each write.
///
/// Note: unlike the fork version, this does NOT forward events to any external
/// telemetry service. Logs stay on disk.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const _maxLines = 500;
File? _logFile;
bool _initialised = false;

Future<void> initAppLog(String homeDir) async {
  try {
    final logsDir = Directory(p.join(homeDir, 'logs'));
    if (!logsDir.existsSync()) logsDir.createSync(recursive: true);
    _logFile = File(p.join(logsDir.path, 'flutter_app.log'));
    _initialised = true;
    appLog('APP', 'Lux Flutter started');
  } catch (e) {
    debugPrint('[AppLog] init failed: $e');
  }
}

/// Log a structured event.
/// category examples: APP, PROXY, CERT, UPDATE, CONN, NET, CORE, WATCHDOG
void appLog(String category, String message) {
  final ts = DateTime.now().toIso8601String();
  final line = '$ts [$category] ${_redactSecrets(message)}';
  debugPrint('[AppLog] $line');

  if (_initialised && _logFile != null) {
    try {
      _logFile!.writeAsStringSync('$line\n', mode: FileMode.append);
      _trimLog();
    } catch (_) {}
  }
}

void _trimLog() {
  try {
    final lines = _logFile!.readAsLinesSync();
    if (lines.length > _maxLines) {
      _logFile!.writeAsStringSync(
        '${lines.sublist(lines.length - _maxLines).join('\n')}\n',
      );
    }
  } catch (_) {}
}

/// Strip anything that looks like a secret/token from the message.
String _redactSecrets(String msg) {
  return msg.replaceAllMapped(
    RegExp(r'(token=|secret=|password=|Bearer )[^\s&"]+', caseSensitive: false),
    (m) => '${m.group(1)}[redacted]',
  );
}
