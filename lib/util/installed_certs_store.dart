import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lux/util/utils.dart';

/// Tracks which CA certificates have been successfully installed.
/// Stores SHA256 fingerprints so we don't prompt the user again.
class InstalledCertsStore {
  static List<String>? _cache;

  static Future<String> get _filePath async {
    final homeDir = await getHomeDir();
    return '$homeDir/installed_certs.json';
  }

  /// Returns the list of installed cert fingerprints.
  static Future<List<String>> getInstalled() async {
    if (_cache != null) return _cache!;
    try {
      final file = File(await _filePath);
      if (!await file.exists()) return [];
      final data = jsonDecode(await file.readAsString());
      _cache = List<String>.from(data['fingerprints'] ?? []);
      return _cache!;
    } catch (e) {
      debugPrint('InstalledCertsStore read error: $e');
      return [];
    }
  }

  /// Returns true if the given fingerprint is already installed.
  static Future<bool> isInstalled(String fingerprint) async {
    if (fingerprint.isEmpty) return false;
    final installed = await getInstalled();
    return installed.contains(fingerprint);
  }

  /// Marks a cert as installed.
  static Future<void> markInstalled(String fingerprint) async {
    if (fingerprint.isEmpty) return;
    final installed = await getInstalled();
    if (installed.contains(fingerprint)) return;
    installed.add(fingerprint);
    _cache = installed;
    try {
      final file = File(await _filePath);
      await file.writeAsString(jsonEncode({'fingerprints': installed}));
    } catch (e) {
      debugPrint('InstalledCertsStore write error: $e');
    }
  }
}
