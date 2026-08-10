// Guards the core-binary checksum gate.
//
// verifyCoreBinary() runs unconditionally on Windows and throws when the constant
// does not match the shipped exe, so the core never starts. On macOS it is skipped
// above macOS 15, which means a stale constant produces no symptom while
// developing on a Mac and a hard launch failure on Windows. Rebuilding the core
// without rerunning scripts/build_core_windows.sh is the whole failure mode, and
// this is what turns that into a failing test instead of a bug report.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/checksum.dart';

Future<String> sha256OfFile(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();

void main() {
  test('windowsAmd64Checksum matches the bundled lux_core.exe', () async {
    final exe = File('assets/bin/lux_core.exe');
    if (!exe.existsSync()) {
      markTestSkipped(
        'assets/bin/lux_core.exe is absent; run scripts/build_core_windows.sh '
        'before building for Windows',
      );
      return;
    }

    final actual = await sha256OfFile(exe);
    expect(
      actual,
      windowsAmd64Checksum,
      reason: 'lib/core/checksum.dart is stale against assets/bin/lux_core.exe. '
          'Windows enforces this on every launch and refuses to start the core. '
          'Run: bash scripts/build_core_windows.sh',
    );
  });

  // The macOS constants are per-architecture, but the bundle ships one universal
  // binary whose digest matches neither slice. That is latent rather than
  // theoretical: it is only survivable because the check is skipped above macOS
  // 15, and it would fail outright on an older release.
  test('darwin checksums cannot match a universal binary', () async {
    final bin = File('assets/bin/lux_core');
    if (!bin.existsSync()) {
      markTestSkipped('assets/bin/lux_core is absent');
      return;
    }

    final isUniversal = await Process.run('file', [bin.path])
        .then((r) => (r.stdout as String).contains('universal binary'));
    if (!isUniversal) {
      markTestSkipped('assets/bin/lux_core is not a universal binary');
      return;
    }

    final actual = await sha256OfFile(bin);
    expect(
      [darwinAmd64Checksum, darwinArm64Checksum].contains(actual),
      isFalse,
      reason: 'A universal binary unexpectedly matched a per-architecture '
          'constant. If the packaging changed to ship a single slice, this test '
          'and the comment above it are out of date.',
    );
  });
}
