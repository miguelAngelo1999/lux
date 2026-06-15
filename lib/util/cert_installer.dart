import 'dart:io';

import 'package:flutter/foundation.dart';

/// Installs a PEM-encoded CA certificate into the platform's trusted root
/// store and into popular terminal tool stores (curl, git, Node.js, Python).
class CertInstaller {
  /// Installs [pemBytes] as a trusted root CA on the current platform.
  /// Returns an [InstallResult] describing what succeeded and what failed.
  static Future<InstallResult> install(List<int> pemBytes) async {
    if (Platform.isMacOS) return _installMacOS(pemBytes);
    if (Platform.isWindows) return _installWindows(pemBytes);
    return InstallResult(
      success: false,
      steps: [],
      error: 'Unsupported platform: ${Platform.operatingSystem}',
    );
  }

  // ── macOS ──────────────────────────────────────────────────────────────────

  static Future<InstallResult> _installMacOS(List<int> pemBytes) async {
    final steps = <InstallStep>[];
    final tmp = File('/tmp/lux_intercept_ca_${DateTime.now().millisecondsSinceEpoch}.pem');
    await tmp.writeAsBytes(pemBytes);

    try {
      // 1. macOS System Keychain — trusted for all users
      final sysExit = await _macOSAsAdmin(
        'security add-trusted-cert -d -r trustRoot '
        '-k /Library/Keychains/System.keychain "${tmp.path}"',
        description: 'Trust CA in System Keychain',
      );
      steps.add(InstallStep(
        name: 'macOS System Keychain',
        success: sysExit == 0,
        note: sysExit == 0 ? 'Trusted system-wide' : 'Exit code: $sysExit',
      ));

      // 2. curl / wget — system OpenSSL cert bundles
      steps.add(await _appendToPemStore(pemBytes, [
        '/etc/ssl/cert.pem',
        '/usr/local/etc/openssl/cert.pem',
        '/opt/homebrew/etc/openssl/cert.pem',
      ], 'curl (system OpenSSL)'));

      // 3. Homebrew openssl@3
      steps.add(await _appendToPemStore(pemBytes, [
        '/opt/homebrew/etc/openssl@3/cert.pem',
        '/usr/local/etc/openssl@3/cert.pem',
      ], 'Homebrew openssl@3'));

      // 4. Git (uses openssl bundle on macOS when installed via Homebrew)
      steps.add(await _appendToPemStore(pemBytes, [
        '/opt/homebrew/etc/openssl@3/cert.pem',
        '/usr/local/etc/openssl@3/cert.pem',
        '/usr/local/etc/openssl/cert.pem',
      ], 'git (Homebrew openssl)'));

      // 5. Node.js / npm — NODE_EXTRA_CA_CERTS in launchd + shell envs
      steps.add(await _macOSNodeExtraCa(pemBytes));

      // 6. Python certifi
      steps.addAll(await _pythonCertifi(pemBytes));
    } finally {
      await tmp.delete().catchError((_) => tmp);
    }

    final ok = steps.any((s) => s.success);
    return InstallResult(success: ok, steps: steps, error: ok ? null : 'All steps failed');
  }

  /// Run a shell command elevated via osascript (one admin prompt).
  static Future<int> _macOSAsAdmin(String cmd, {required String description}) async {
    final script =
        'do shell script "$cmd" with prompt "Lux: $description" with administrator privileges';
    final r = await Process.run('/usr/bin/osascript', ['-e', script]);
    debugPrint('macOS admin [$description] exit=${r.exitCode} err=${r.stderr}');
    return r.exitCode;
  }

  static Future<InstallStep> _macOSNodeExtraCa(List<int> pemBytes) async {
    const dest = '/etc/ssl/certs/lux_intercept_ca.pem';
    final tmp = File('/tmp/lux_node_ca_${DateTime.now().millisecondsSinceEpoch}.pem');
    await tmp.writeAsBytes(pemBytes);
    try {
      final cpExit = await _macOSAsAdmin(
        'cp "${tmp.path}" "$dest" && chmod 644 "$dest"',
        description: 'Install CA for Node.js/npm',
      );
      if (cpExit != 0) {
        return InstallStep(name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)', success: false,
            note: 'Could not write to $dest');
      }
      const line = 'setenv NODE_EXTRA_CA_CERTS $dest';
      final launchd = File('/etc/launchd.conf');
      String existing = '';
      try { if (await launchd.exists()) existing = await launchd.readAsString(); } catch (_) {}
      if (!existing.contains('NODE_EXTRA_CA_CERTS')) {
        await _macOSAsAdmin('echo "$line" >> /etc/launchd.conf',
            description: 'Set NODE_EXTRA_CA_CERTS in launchd.conf');
      }
      for (final f in ['/etc/zshenv', '/etc/profile.d/lux_ca.sh']) {
        try {
          String fc = '';
          final ff = File(f);
          if (await ff.exists()) { try { fc = await ff.readAsString(); } catch (_) {} }
          if (!fc.contains('NODE_EXTRA_CA_CERTS')) {
            await _macOSAsAdmin(
              "echo 'export NODE_EXTRA_CA_CERTS=$dest' >> $f",
              description: 'Set NODE_EXTRA_CA_CERTS in $f',
            );
          }
        } catch (_) {}
      }
      return InstallStep(name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)', success: true,
          note: 'Cert at $dest; set in launchd.conf + /etc/zshenv');
    } finally {
      await tmp.delete().catchError((_) => tmp);
    }
  }

  // ── Windows ────────────────────────────────────────────────────────────────

  static Future<InstallResult> _installWindows(List<int> pemBytes) async {
    final steps = <InstallStep>[];
    final tmp = File(
        '${Directory.systemTemp.path}\\lux_ca_${DateTime.now().millisecondsSinceEpoch}.pem');
    await tmp.writeAsBytes(pemBytes);

    try {
      // 1. Windows Trusted Root store (all users)
      final certutilExit = await _windowsAsAdmin(
          'certutil -addstore -f Root "${tmp.path}"',
          description: 'Install CA into Windows Trusted Root');
      steps.add(InstallStep(
        name: 'Windows Trusted Root (certutil)',
        success: certutilExit == 0,
        note: certutilExit == 0 ? 'Installed to LocalMachine\\Root' : 'Exit: $certutilExit',
      ));

      // 2. curl on Windows piggybacks the Windows cert store — no extra action
      steps.add(InstallStep(
        name: 'curl (uses Windows cert store)',
        success: certutilExit == 0,
        note: certutilExit == 0 ? 'Covered by certutil' : 'Skipped',
      ));

      // 3. Git for Windows
      steps.add(await _gitWindowsCerts(pemBytes));

      // 4. Node.js / npm via HKLM env
      steps.add(await _windowsNodeExtraCa(pemBytes));

      // 5. Python certifi
      steps.addAll(await _pythonCertifi(pemBytes));
    } finally {
      await tmp.delete().catchError((_) => tmp);
    }

    final ok = steps.any((s) => s.success);
    return InstallResult(success: ok, steps: steps, error: ok ? null : 'All steps failed');
  }

  /// Run a command elevated via PowerShell Start-Process -Verb RunAs.
  static Future<int> _windowsAsAdmin(String cmd, {required String description}) async {
    final bat = File(
        '${Directory.systemTemp.path}\\lux_admin_${DateTime.now().millisecondsSinceEpoch}.bat');
    await bat.writeAsString('@echo off\r\n$cmd\r\n');
    try {
      final r = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        'Start-Process cmd.exe -Verb RunAs -Wait '
            '-ArgumentList "/c \\"${bat.path}\\"" -WindowStyle Hidden',
      ]);
      debugPrint('Windows admin [$description] exit=${r.exitCode}');
      return r.exitCode;
    } finally {
      await bat.delete().catchError((_) => bat);
    }
  }

  static Future<InstallStep> _gitWindowsCerts(List<int> pemBytes) async {
    for (final path in [
      r'C:\Program Files\Git\usr\ssl\certs\ca-bundle.crt',
      r'C:\Program Files (x86)\Git\usr\ssl\certs\ca-bundle.crt',
    ]) {
      if (await File(path).exists()) {
        final step = await _appendToPemStore(pemBytes, [path], 'Git for Windows (ca-bundle.crt)');
        if (step.success) return step;
      }
    }
    return InstallStep(
        name: 'Git for Windows (ca-bundle.crt)', success: false,
        note: 'Git for Windows not found');
  }

  static Future<InstallStep> _windowsNodeExtraCa(List<int> pemBytes) async {
    const dir = r'C:\ProgramData\lux';
    const dest = r'C:\ProgramData\lux\intercept_ca.pem';
    try {
      await Directory(dir).create(recursive: true);
      await File(dest).writeAsBytes(pemBytes);
      final regExit = await _windowsAsAdmin(
        'reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" '
        '/v NODE_EXTRA_CA_CERTS /t REG_SZ /d "$dest" /f',
        description: 'Set NODE_EXTRA_CA_CERTS for Node.js',
      );
      return InstallStep(
        name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)',
        success: regExit == 0,
        note: regExit == 0 ? 'Set NODE_EXTRA_CA_CERTS=$dest in system env' : 'Registry write failed',
      );
    } catch (e) {
      return InstallStep(name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)', success: false, note: '$e');
    }
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  /// Appends [pemBytes] to the first writable path in [paths].
  static Future<InstallStep> _appendToPemStore(
      List<int> pemBytes, List<String> paths, String storeName) async {
    for (final path in paths) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        final existing = await f.readAsString();
        final pemStr = String.fromCharCodes(pemBytes);
        // Dedup: skip if the cert body is already present
        final body = _pemBody(pemStr);
        if (body.isNotEmpty && existing.contains(body)) {
          return InstallStep(name: storeName, success: true, note: 'Already present in $path');
        }
        final raf = await f.open(mode: FileMode.append);
        await raf.writeString('\n# Added by Lux SSL inspection CA\n');
        await raf.writeFrom(pemBytes);
        await raf.close();
        return InstallStep(name: storeName, success: true, note: 'Appended to $path');
      } catch (e) {
        debugPrint('Failed to write to $path: $e');
      }
    }
    return InstallStep(
        name: storeName, success: false,
        note: 'No writable store found in: ${paths.join(', ')}');
  }

  static String _pemBody(String pem) {
    final body = pem
        .split('\n')
        .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
        .join('');
    return body.length > 32 ? body.substring(0, 32) : body;
  }

  /// Finds Python certifi's cacert.pem and appends the cert to it.
  static Future<List<InstallStep>> _pythonCertifi(List<int> pemBytes) async {
    for (final python in ['python3', 'python', 'python3.12', 'python3.11']) {
      try {
        final r = await Process.run(
          Platform.isWindows ? python : '/usr/bin/env',
          Platform.isWindows
              ? [python, '-c', 'import certifi; print(certifi.where())']
              : [python, '-c', 'import certifi; print(certifi.where())'],
        );
        if (r.exitCode != 0) continue;
        final certifiPath = r.stdout.toString().trim();
        if (certifiPath.isEmpty) continue;
        final step = await _appendToPemStore(pemBytes, [certifiPath], 'Python certifi ($python)');
        return [step];
      } catch (_) {
        continue;
      }
    }
    return [InstallStep(
        name: 'Python certifi', success: false,
        note: 'Python not found or certifi not installed')];
  }
}

/// Result of a full certificate installation attempt.
class InstallResult {
  final bool success;
  final List<InstallStep> steps;
  final String? error;
  const InstallResult({required this.success, required this.steps, this.error});
}

/// Outcome of a single installation step.
class InstallStep {
  final String name;
  final bool success;
  final String note;
  const InstallStep({required this.name, required this.success, required this.note});
}
