/// Persistent blackbox event log for debugging Lux crashes and issues.
/// Writes timestamped events to a rotating log file alongside lux_core logs.
/// Also forwards events to the telemetry service (if enabled).
/// Max 500 lines — older entries are trimmed on each write.
library app_log;

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lux/util/telemetry.dart' as telem;
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
/// category examples: APP, PROXY, CERT, WIZARD, UPDATE, CONN, NET, CORE, WATCHDOG
void appLog(String category, String message) {
  final ts = DateTime.now().toIso8601String();
  final line = '$ts [$category] $message';
  debugPrint('[AppLog] $line');

  // Write to local log file
  if (_initialised && _logFile != null) {
    try {
      _logFile!.writeAsStringSync('$line\n', mode: FileMode.append);
      _trimLog();
    } catch (_) {}
  }

  // Forward to telemetry (ops level — no domain data here)
  // Skip very noisy / low-value categories to save sheet rows
  if (!_isNoisy(category, message)) {
    telem.telemetryOp(category, _redactSecrets(message));
  }
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

/// Returns true for log lines that are too frequent/noisy to send.
bool _isNoisy(String category, String message) {
  if (category == 'WATCHDOG' && message.contains('ok')) return true;
  if (category == 'NET-DETECT' && message.contains('skipping')) return true;
  if (category == 'UPDATE' && message.contains('progress')) return true;
  if (category == 'PROXY-CFG' && message.contains('sudo -n')) return true;
  return false;
}

/// Strip anything that looks like a secret/token from the message.
String _redactSecrets(String msg) {
  // token=xxxx → token=[redacted]
  return msg.replaceAllMapped(
    RegExp(r'(token=|secret=|password=|Bearer )[^\s&"]+', caseSensitive: false),
    (m) => '${m.group(1)}[redacted]',
  );
}
