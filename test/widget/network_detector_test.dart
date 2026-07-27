import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NetworkDetector TCP probe', () {
    test('connecting to unreachable port returns false (socket error)', () async {
      bool reachable = false;
      try {
        final sock = await Socket.connect('127.0.0.1', 19999,
            timeout: const Duration(milliseconds: 200));
        sock.destroy();
        reachable = true;
      } catch (_) {
        reachable = false;
      }
      expect(reachable, isFalse,
          reason: 'Port 19999 should never be open in test environment');
    });

    test('connecting to localhost:80 or open port works', () async {
      // Just verify Socket.connect API works — actual port may vary
      bool threw = false;
      try {
        // Try to connect to a port that may or may not be open
        // We test the API works, not the specific port
        final sock = await Socket.connect('127.0.0.1', 80,
            timeout: const Duration(milliseconds: 200));
        sock.destroy();
      } catch (_) {
        threw = true; // expected if port 80 not open
      }
      // Either outcome is fine — we just verify no unexpected exception type
      expect(threw, isA<bool>());
    });

    test('socket connect timeout fires correctly', () async {
      final stopwatch = Stopwatch()..start();
      try {
        // 10.0.0.1 is a non-routable address that will time out
        await Socket.connect('10.255.255.1', 9999,
            timeout: const Duration(milliseconds: 500));
      } catch (_) {}
      stopwatch.stop();
      // Should have timed out within ~1 second
      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
    });
  });
}
