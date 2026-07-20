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

    // First pass: normalize all keys to no-colon format
    final normalized = <String, dynamic>{};
    for (final k in certs.keys) {
      final cleanKey = _normalizeFp(k);
      if (normalized.containsKey(cleanKey)) {
        // Merge duplicate entries (colon + no-colon version of same cert)
        final existing = normalized[cleanKey] as Map<String, dynamic>;
        final incoming = certs[k] as Map<String, dynamic>;
        final merged = <String>{
          ...List<String>.from(existing['stores'] ?? []),
          ...List<String>.from(incoming['stores'] ?? []),
        }.toList();
        normalized[cleanKey] = {...existing, 'stores': merged};
      } else {
        normalized[cleanKey] = certs[k];
      }
      if (cleanKey != k) changed = true;
    }

    // Second pass: normalize store names
    for (final fp in normalized.keys) {
      final entry = normalized[fp] as Map<String, dynamic>;
      final stores = List<String>.from(entry['stores'] ?? []);
      final migrated = stores.map((s) {
        if (s == 'Node.js (NODE_EXTRA_CA_CERTS)') return 'Node.js / npm (NODE_EXTRA_CA_CERTS)';
        if (s == 'Firefox (NSS)') return 'Firefox / Thunderbird (NSS)';
        if (s == 'Thunderbird (NSS)') return 'Firefox / Thunderbird (NSS)';
        if (s.startsWith('Python certifi')) return 'Python certifi';
        if (s == 'Windows Trusted Root') return 'Windows Trusted Root (certutil)';
        if (s == 'Git for Windows') return 'Git for Windows (ca-bundle.crt)';
        return s;
      }).toSet().toList();
      if (!_setEqual(stores.toSet(), migrated.toSet())) {
        normalized[fp] = {...entry, 'stores': migrated};
        changed = true;
      }
    }

    if (changed) { _cache = normalized; await _write(); }
    else { _cache = normalized; } // keep normalized even if no changes
  }

  static bool _setEqual(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  static String _normalizeFp(String fp) =>
      fp.toLowerCase().replaceAll(':', '').replaceAll(' ', '');

  static Future<bool> isFullyInstalled(String fingerprint) async {
    if (fingerprint.isEmpty) return false;
    final fp = _normalizeFp(fingerprint);
    final certs = await _read();

    // Look up by normalized key (handles both colon and no-colon formats)
    String? matchKey;
    for (final k in certs.keys) {
      if (_normalizeFp(k) == fp) { matchKey = k; break; }
    }
    if (matchKey == null) return false;

    final entry = certs[matchKey] as Map<String, dynamic>;
    final installedStores = List<String>.from(entry['stores'] ?? []);
    if (Platform.isMacOS && !installedStores.contains('macOS System Keychain')) return false;
    if (Platform.isWindows && !installedStores.contains('Windows Trusted Root (certutil)')) return false;
    return installedStores.isNotEmpty;
  }

  static Future<void> markInstalled(String fingerprint, List<String> storeNames) async {
    if (fingerprint.isEmpty || storeNames.isEmpty) return;
    final fp = _normalizeFp(fingerprint); // always store without colons
    final certs = await _read();

    // Find existing entry regardless of old colon format
    String? existingKey;
    for (final k in certs.keys) {
      if (_normalizeFp(k) == fp) { existingKey = k; break; }
    }

    if (existingKey != null && existingKey != fp) {
      // Migrate old colon-format key to clean format
      certs[fp] = certs.remove(existingKey)!;
    }

    if (certs.containsKey(fp)) {
      final entry = certs[fp] as Map<String, dynamic>;
      final existing = List<String>.from(entry['stores'] ?? []);
      certs[fp] = {
        'installedAt': entry['installedAt'] ?? DateTime.now().toIso8601String(),
        'stores': {...existing, ...storeNames}.toList(),
      };
    } else {
      certs[fp] = {
        'installedAt': DateTime.now().toIso8601String(),
        'stores': storeNames,
      };
    }

    _cache = certs;
    await _write();
  }

  /// Returns stores that exist on this machine but don't have the cert installed.
  static Future<List<String>> getMissingStores(String fingerprint) async {
    if (fingerprint.isEmpty) return [];
    final fp = _normalizeFp(fingerprint);
    final certs = await _read();

    String? matchKey;
    for (final k in certs.keys) {
      if (_normalizeFp(k) == fp) { matchKey = k; break; }
    }
    if (matchKey == null) return await _detectAvailableStores();

    final entry = certs[matchKey] as Map<String, dynamic>;
    final installedStores = List<String>.from(entry['stores'] ?? []);
    final currentStores = await _detectAvailableStores();
    return currentStores.where((s) => !installedStores.contains(s)).toList();
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
        if (r.exitCode == 0 && r.stdout.toString().trim().isNotEmpty) {
          stores.add('Python certifi'); // normalized name
        }
      } catch (_) {}

      // Firefox / Thunderbird (NSS)
      final home = Platform.environment['HOME'] ?? '';
      final firefoxProfiles = Directory('$home/Library/Application Support/Firefox/Profiles');
      final tbProfiles = Directory('$home/Library/Application Support/Thunderbird/Profiles');
      bool hasNss = false;
      if (await firefoxProfiles.exists()) {
        hasNss = await firefoxProfiles.list().any((e) =>
            e is Directory && (File('${e.path}/cert9.db').existsSync() || File('${e.path}/cert8.db').existsSync()));
      }
      if (!hasNss && await tbProfiles.exists()) {
        hasNss = await tbProfiles.list().any((e) =>
            e is Directory && (File('${e.path}/cert9.db').existsSync() || File('${e.path}/cert8.db').existsSync()));
      }
      if (hasNss) stores.add('Firefox / Thunderbird (NSS)'); // normalized name

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
      stores.add('Windows Trusted Root (certutil)');
      stores.add('Node.js / npm (NODE_EXTRA_CA_CERTS)');
      // curl on Windows uses the Windows cert store — always add it
      stores.add('curl (uses Windows cert store)');

      // Git for Windows
      for (final p in [r'C:\Program Files\Git\usr\ssl\certs\ca-bundle.crt', r'C:\Program Files (x86)\Git\usr\ssl\certs\ca-bundle.crt']) {
        if (await File(p).exists()) { stores.add('Git for Windows (ca-bundle.crt)'); break; }
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
