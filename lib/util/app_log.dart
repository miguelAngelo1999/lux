/// Persistent blackbox event log for debugging Lux crashes and issues.
/// Writes timestamped events to a rotating log file alongside lux_core logs.
/// Max 500 lines — older entries are trimmed on each write.
library app_log;

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
    appLog('APP', 'Lux Flutter started — version 1.44.0');
  } catch (e) {
    debugPrint('[AppLog] init failed: $e');
  }
}

/// Log a structured event. category examples: APP, PROXY, CERT, WIZARD, UPDATE, CONN, NET
void appLog(String category, String message) {
  final ts = DateTime.now().toIso8601String();
  final line = '$ts [$category] $message';
  debugPrint('[AppLog] $line');
  if (!_initialised || _logFile == null) return;
  try {
    _logFile!.writeAsStringSync('$line\n', mode: FileMode.append);
    _trimLog();
  } catch (_) {}
}

void _trimLog() {
  try {
    final lines = _logFile!.readAsLinesSync();
    if (lines.length > _maxLines) {
      _logFile!.writeAsStringSync(
        lines.sublist(lines.length - _maxLines).join('\n') + '\n',
      );
    }
  } catch (_) {}
}
