import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lux/util/utils.dart';

/// Tracks which CA certificates have been installed and into which stores.
/// On each launch, checks if new stores appeared (e.g. Firefox installed after
/// the cert was first trusted) and prompts to install only into the new ones.
///
/// File format:
/// ```json
/// {
///   "certs": {
///     "<sha256_fingerprint>": {
///       "installedAt": "2026-06-17T12:00:00Z",
///       "stores": ["macOS System Keychain", "curl (system OpenSSL)", "Node.js", ...]
///     }
///   }
/// }
/// ```
class InstalledCertsStore {
  static Map<String, dynamic>? _cache;

  static Future<String> get _filePath async {
    final homeDir = await getHomeDir();
    return '$homeDir/installed_certs.json';
  }

  static Future<Map<String, dynamic>> _read() async {
    if (_cache != null) return _cache!;
    try {
      final file = File(await _filePath);
      if (!await file.exists()) return {};
      final data = jsonDecode(await file.readAsString());
      _cache = Map<String, dynamic>.from(data['certs'] ?? {});
      return _cache!;
    } catch (e) {
      debugPrint('InstalledCertsStore read error: $e');
      return {};
    }
  }

  static Future<void> _write() async {
    try {
      final file = File(await _filePath);
      await file.writeAsString(jsonEncode({'certs': _cache ?? {}}));
    } catch (e) {
      debugPrint('InstalledCertsStore write error: $e');
    }
  }

  /// Clears the in-memory cache, forcing the next read to reload from disk.
  /// Also migrates old store name mismatches so isFullyInstalled works correctly.
  static Future<void> ensureConsistentStoreNames() async {
    _cache = null; // force reload
    final certs = await _read();
    bool changed = false;
    for (final fp in certs.keys) {
      final entry = certs[fp] as Map<String, dynamic>;
      final stores = List<String>.from(entry['stores'] ?? []);
      // Migrate old name → new name
      final migrated = stores.map((s) {
        if (s == 'Node.js (NODE_EXTRA_CA_CERTS)') return 'Node.js / npm (NODE_EXTRA_CA_CERTS)';
        return s;
      }).toList();
      if (!_listEqual(stores, migrated)) {
        certs[fp] = {...entry, 'stores': migrated};
        changed = true;
      }
    }
    if (changed) { _cache = certs; await _write(); }
  }

  static bool _listEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
  }

  /// Returns true if the cert is installed in ALL currently available stores.
  /// Returns false if there are new stores that don't have the cert yet.
  static Future<bool> isFullyInstalled(String fingerprint) async {
    if (fingerprint.isEmpty) return false;
    final certs = await _read();
    if (!certs.containsKey(fingerprint)) return false;

    final entry = certs[fingerprint] as Map<String, dynamic>;
    final installedStores = List<String>.from(entry['stores'] ?? []);

    // Check if there are new stores available that weren't patched
    final currentStores = await _detectAvailableStores();
    final missingStores = currentStores.where((s) => !installedStores.contains(s)).toList();

    return missingStores.isEmpty;
  }

  /// Returns stores that exist on this machine but don't have the cert installed.
  static Future<List<String>> getMissingStores(String fingerprint) async {
    if (fingerprint.isEmpty) return [];
    final certs = await _read();
    if (!certs.containsKey(fingerprint)) return await _detectAvailableStores();

    final entry = certs[fingerprint] as Map<String, dynamic>;
    final installedStores = List<String>.from(entry['stores'] ?? []);
    final currentStores = await _detectAvailableStores();

    return currentStores.where((s) => !installedStores.contains(s)).toList();
  }

  /// Records that a cert was installed into specific stores.
  static Future<void> markInstalled(String fingerprint, List<String> storeNames) async {
    if (fingerprint.isEmpty || storeNames.isEmpty) return;
    final certs = await _read();

    if (certs.containsKey(fingerprint)) {
      final entry = certs[fingerprint] as Map<String, dynamic>;
      final existing = List<String>.from(entry['stores'] ?? []);
      final merged = {...existing, ...storeNames}.toList();
      certs[fingerprint] = {
        'installedAt': entry['installedAt'] ?? DateTime.now().toIso8601String(),
        'stores': merged,
      };
    } else {
      certs[fingerprint] = {
        'installedAt': DateTime.now().toIso8601String(),
        'stores': storeNames,
      };
    }

    _cache = certs;
    await _write();
  }

  /// Detects which cert stores currently exist on this machine.
  static Future<List<String>> _detectAvailableStores() async {
    final stores = <String>[];

    if (Platform.isMacOS) {
      // System Keychain always exists
      stores.add('macOS System Keychain');

      // OpenSSL stores
      for (final p in ['/etc/ssl/cert.pem', '/opt/homebrew/etc/openssl/cert.pem', '/usr/local/etc/openssl/cert.pem']) {
        if (await File(p).exists()) { stores.add('curl (system OpenSSL)'); break; }
      }

      // Node.js
      stores.add('Node.js / npm (NODE_EXTRA_CA_CERTS)');

      // Homebrew openssl@3
      for (final p in ['/opt/homebrew/etc/openssl@3/cert.pem', '/usr/local/etc/openssl@3/cert.pem']) {
        if (await File(p).exists()) { stores.add('Homebrew openssl@3'); break; }
      }

      // Python certifi
      try {
        final r = await Process.run('/usr/bin/env', ['python3', '-c', 'import certifi; print(certifi.where())']);
        if (r.exitCode == 0 && r.stdout.toString().trim().isNotEmpty) stores.add('Python certifi');
      } catch (_) {}

      // Firefox
      final home = Platform.environment['HOME'] ?? '';
      final firefoxProfiles = Directory('$home/Library/Application Support/Firefox/Profiles');
      if (await firefoxProfiles.exists()) {
        final hasDb = await firefoxProfiles.list().any((e) =>
            e is Directory && (File('${e.path}/cert9.db').existsSync() || File('${e.path}/cert8.db').existsSync()));
        if (hasDb) stores.add('Firefox (NSS)');
      }

      // Thunderbird
      final tbProfiles = Directory('$home/Library/Application Support/Thunderbird/Profiles');
      if (await tbProfiles.exists()) {
        final hasDb = await tbProfiles.list().any((e) =>
            e is Directory && (File('${e.path}/cert9.db').existsSync() || File('${e.path}/cert8.db').existsSync()));
        if (hasDb) stores.add('Thunderbird (NSS)');
      }

      // App bundles (Anaconda, DaVinci, etc.)
      final appBundlePaths = [
        '$home/anaconda3/ssl/cacert.pem',
        '$home/miniconda3/ssl/cacert.pem',
        '/Library/Application Support/Blackmagic Design/DaVinci Resolve/curl-ca-bundle.crt',
      ];
      for (final p in appBundlePaths) {
        if (await File(p).exists()) { stores.add('App cert bundles'); break; }
      }
    } else if (Platform.isWindows) {
      stores.add('Windows Trusted Root');
      stores.add('Node.js / npm (NODE_EXTRA_CA_CERTS)');

      // Git for Windows
      for (final p in [r'C:\Program Files\Git\usr\ssl\certs\ca-bundle.crt', r'C:\Program Files (x86)\Git\usr\ssl\certs\ca-bundle.crt']) {
        if (await File(p).exists()) { stores.add('Git for Windows'); break; }
      }

      // Python certifi
      try {
        final r = await Process.run('python', ['-c', 'import certifi; print(certifi.where())']);
        if (r.exitCode == 0 && r.stdout.toString().trim().isNotEmpty) stores.add('Python certifi');
      } catch (_) {}
    }

    return stores;
  }
}
