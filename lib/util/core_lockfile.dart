import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// Fixed port used when the LaunchAgent pre-starts lux_core on macOS.
/// Windows uses dynamic port allocation — this constant is macOS-only.
const luxCoreFixedPort = 18000;

/// Data written to the lockfile so Flutter can reconnect to a pre-started
/// lux_core (LaunchAgent mode) without re-launching it.
class CoreLockfile {
  final int port;
  final String secret;

  const CoreLockfile({required this.port, required this.secret});

  factory CoreLockfile.fromJson(Map<String, dynamic> json) => CoreLockfile(
        port: (json['port'] as num).toInt(),
        secret: json['secret'] as String,
      );

  Map<String, dynamic> toJson() => {'port': port, 'secret': secret};
}

String _lockfilePath(String homeDir) =>
    path.join(homeDir, 'lux_core.lock');

/// Reads the lockfile. Returns null if it doesn't exist or is malformed.
Future<CoreLockfile?> readLockfile(String homeDir) async {
  final f = File(_lockfilePath(homeDir));
  if (!await f.exists()) return null;
  try {
    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return CoreLockfile.fromJson(data);
  } catch (_) {
    return null;
  }
}

/// Writes the lockfile.
Future<void> writeLockfile(String homeDir, CoreLockfile lock) async {
  final f = File(_lockfilePath(homeDir));
  await f.parent.create(recursive: true);
  await f.writeAsString(jsonEncode(lock.toJson()));
}

/// Deletes the lockfile if it exists.
Future<void> deleteLockfile(String homeDir) async {
  final f = File(_lockfilePath(homeDir));
  if (await f.exists()) await f.delete();
}
