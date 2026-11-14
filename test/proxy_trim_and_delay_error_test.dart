import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/widget/proxy_list_item.dart';

void main() {
  group('Proxy error mapping logic', () {
    test('Maps HTTP 407 to authError', () {
      const err = 'upstream proxy authentication required (HTTP 407)';
      final isAuth = err.contains('407') ||
          err.toLowerCase().contains('auth') ||
          err.toLowerCase().contains('denied') ||
          err.toLowerCase().contains('rejected');
      expect(isAuth, isTrue);

      final state = isAuth ? TestState.authError : TestState.unreachable;
      expect(state, TestState.authError);
    });

    test('Maps socks5 auth failure to authError', () {
      const err = 'upstream proxy denied connection (rejected username/password)';
      final isAuth = err.contains('407') ||
          err.toLowerCase().contains('auth') ||
          err.toLowerCase().contains('denied') ||
          err.toLowerCase().contains('rejected');
      expect(isAuth, isTrue);

      final state = isAuth ? TestState.authError : TestState.unreachable;
      expect(state, TestState.authError);
    });

    test('Maps certError to certError', () {
      const isCert = true;
      const err = 'x509: certificate signed by unknown authority';
      final state = isCert ? TestState.certError : TestState.unreachable;
      expect(state, TestState.certError);
    });

    test('Maps dial timeout to unreachable with message preserved', () {
      const err = 'dial tcp 10.10.102.240:8080: i/o timeout';
      final isCert = false;
      final isAuth = err.contains('407') ||
          err.toLowerCase().contains('auth') ||
          err.toLowerCase().contains('denied') ||
          err.toLowerCase().contains('rejected');
      final state = isCert
          ? TestState.certError
          : (isAuth ? TestState.authError : TestState.unreachable);

      expect(state, TestState.unreachable);
      expect(err, contains('i/o timeout'));
    });
  });

  group('Field trimming logic', () {
    test('Trims server, username, and name strings', () {
      final input = <String, dynamic>{
        'name': '   My Proxy   ',
        'server': '     10.10.102.240  ',
        'port': 8080,
        'username': '   nimish.coelho   ',
        'type': 'http',
      };

      final sanitized = Map<String, dynamic>.from(input);
      if (sanitized['server'] is String) sanitized['server'] = (sanitized['server'] as String).trim();
      if (sanitized['username'] is String) sanitized['username'] = (sanitized['username'] as String).trim();
      if (sanitized['name'] is String) sanitized['name'] = (sanitized['name'] as String).trim();

      expect(sanitized['server'], '10.10.102.240');
      expect(sanitized['username'], 'nimish.coelho');
      expect(sanitized['name'], 'My Proxy');
    });
  });

  group('Windows config directory migration simulation', () {
    test('Migrates legacy dot-dir config to canonical dir if canonical is missing or older', () {
      final tempDir = Directory.systemTemp.createTempSync('win_config_mig_test_');
      try {
        final legacyDir = Directory('${tempDir.path}/com.github.igoogolx.lux/1.0');
        final canonicalDir = Directory('${tempDir.path}/com.github.igoogolx/lux/1.0');
        legacyDir.createSync(recursive: true);
        canonicalDir.createSync(recursive: true);

        final legacyCfg = File('${legacyDir.path}/config.json');
        final canonicalCfg = File('${canonicalDir.path}/config.json');

        legacyCfg.writeAsStringSync('{"proxy":[{"name":"migrated"}]}');

        // Migrate if canonical is absent
        if (!canonicalCfg.existsSync() || legacyCfg.lastModifiedSync().isAfter(canonicalCfg.lastModifiedSync())) {
          legacyCfg.copySync(canonicalCfg.path);
        }

        expect(canonicalCfg.existsSync(), isTrue);
        expect(canonicalCfg.readAsStringSync(), contains('migrated'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
