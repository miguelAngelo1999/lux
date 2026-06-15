import 'dart:io';

import 'package:flutter/foundation.dart';

/// Installs a PEM-encoded CA certificate into the platform's trusted root
/// store and into popular terminal tool stores (curl, git, etc.).
class CertInstaller {
  /// Installs [pemBytes] as a trusted root CA on the current platform.
  ///
  /// Returns an [InstallResult] describing what succeeded and what failed.
  static Future<InstallResult> install(List<int> pemBytes) async {
    if (Platform.isMacOS) {
      return _installMacOS(pemBytes);
    } else if (Platform.isWindows) {
      return _installWindows(pemBytes);
    }
    return InstallResult(
      success: false,
      steps: [],
      error: 'Unsupported platform: ${Platform.operatingSystem}',
    );
  }

  // ── macOS ──────────────────────────────────────────────────────────────────

  static Future<InstallResult> _installMacOS(List<int> pemBytes) async {
    final steps = <InstallStep>[];

    // Write PEM to a temp file
    final tmpFile = File('/tmp/lux_intercept_ca_${DateTime.now().millisecondsSinceEpoch}.pem');
    await tmpFile.writeAsBytes(pemBytes);

    try {
      // 1. Install into macOS System keychain (trusted for all users)
      final sysResult = await _runMacOSAsAdmin(
        'security add-trusted-cert -d -r trustRoot '
        '-k /Library/Keychains/System.keychain "${tmpFile.path}"',
        description: 'Trusting cert in System keychain',
      );
      steps.add(InstallStep(
        name: 'macOS System Keychain',
        success: sysResult == 0,
        note: sysResult == 0 ? 'Trusted system-wide' : 'Exit code: $sysResult',
      ));

      // 2. curl — /etc/ssl/cert.pem or /usr/local/etc/openssl/cert.pem
      steps.add(await _appendToPemStore(
        pemBytes,
        _macOSCurlCertStores(),
        'curl (system OpenSSL)',
      ));

      // 3. Git uses its own bundle (usually points at macOS SecureTransport,
      //    but homebrew git may have its own store)
      steps.add(await _appendToPemStore(
        pemBytes,
        _macOSGitCertStores(),
        'git (homebrew bundle)',
      ));

      // 4. Homebrew's openssl ca-bundle
      steps.add(await _appendToPemStore(
        pemBytes,
        ['/opt/homebrew/etc/openssl@3/cert.pem', '/usr/local/etc/openssl@3/cert.pem'],
        'Homebrew openssl@3',
      ));

      // 5. Python certifi (most common location)
      steps.addAll(await _installPythonCertifi(pemBytes));

      // 6. Node.js / npm — respects NODE_EXTRA_CA_CERTS env var.
      //    We write the cert to a well-known location and add an
      //    /etc/profile.d entry so it's picked up system-wide.
      steps.add(await _installNodeExtraCa(pemBytes));
    } finally {
      await tmpFile.delete().catchError((_) => tmpFile);
    }

    final anySuccess = steps.any((s) => s.success);
    return InstallResult(
      success: anySuccess,
      steps: steps,
      error: anySuccess ? null : 'All installation steps failed',
    );
  }

  /// Runs a shell command elevated via osascript (prompts for admin once).
  static Future<int> _runMacOSAsAdmin(String cmd, {required String description}) async {
    final script = 'do shell script "$cmd" with prompt '
        '"Lux: $description" with administrator privileges';
    final result = await Process.run('/usr/bin/osascript', ['-e', script]);
    debugPrint('macOS admin cmd [$description] exit=${result.exitCode} '
        'err=${result.stderr}');
    return result.exitCode;
  }

  static List<String> _macOSCurlCertStores() => [
        '/etc/ssl/cert.pem',
        '/usr/local/etc/openssl/cert.pem',
        '/opt/homebrew/etc/openssl/cert.pem',
      ];

  static List<String> _macOSGitCertStores() => [
        '/usr/local/etc/openssl@3/cert.pem',
        '/opt/homebrew/etc/openssl@3/cert.pem',
        '/usr/local/share/ca-certificates/lux_intercept_ca.crt',
      ];

  // ── Windows ────────────────────────────────────────────────────────────────

  static Future<InstallResult> _installWindows(List<int> pemBytes) async {
    final steps = <InstallStep>[];

    // Convert PEM → CER (DER) for certutil
    final tmpPem = File(
        '${Directory.systemTemp.path}\\lux_intercept_ca_${DateTime.now().millisecondsSinceEpoch}.pem');
    await tmpPem.writeAsBytes(pemBytes);

    try {
      // 1. Windows Trusted Root store (all users via LocalMachine)
      final certutilResult = await _runWindowsAsAdmin(
        'certutil -addstore -f Root "${tmpPem.path}"',
        description: 'Installing CA into Windows Trusted Root store',
      );
      steps.add(InstallStep(
        name: 'Windows Trusted Root (certutil)',
        success: certutilResult == 0,
        note: certutilResult == 0
            ? 'Installed to LocalMachine\\Root'
            : 'certutil exit code: $certutilResult',
      ));

      // 2. curl on Windows (curl ships with Windows 10+, uses Windows cert store).
      //    No separate action needed — it piggybacks the certutil install above.
      steps.add(InstallStep(
        name: 'curl (uses Windows cert store)',
        success: certutilResult == 0,
        note: certutilResult == 0
            ? 'Covered by certutil install'
            : 'Skipped — certutil install failed',
      ));

      // 3. Git for Windows (git-scm) has its own bundled OpenSSL cert bundle
      steps.add(await _installGitWindowsCerts(pemBytes));

      // 4. Node.js / npm — NODE_EXTRA_CA_CERTS environment variable
      steps.add(await _installWindowsNodeExtraCa(pemBytes));

      // 5. Python certifi (most common location)
      steps.addAll(await _installPythonCertifi(pemBytes));
    } finally {
      await tmpPem.delete().catchError((_) => tmpPem);
    }

    final anySuccess = steps.any((s) => s.success);
    return InstallResult(
      success: anySuccess,
      steps: steps,
      error: anySuccess ? null : 'All installation steps failed',
    );
  }

  /// Runs a command elevated via PowerShell Start-Process -Verb RunAs.
  static Future<int> _runWindowsAsAdmin(String cmd,
      {required String description}) async {
    // Write the command to a temp script to avoid quoting nightmares
    final scriptFile = File(
        '${Directory.systemTemp.path}\\lux_admin_${DateTime.now().millisecondsSinceEpoch}.bat');
    await scriptFile.writeAsString('@echo off\r\n$cmd\r\n');

    try {
      final result = await Process.run('powershell.exe', [
        '-noprofile',
        '-NonInteractive',
        '-command',
        'Start-Process cmd.exe -Verb RunAs -Wait '
            '-ArgumentList "/c \\"${scriptFile.path}\\"" '
            '-WindowStyle Hidden',
      ]);
      debugPrint('Windows admin cmd [$description] exit=${result.exitCode} '
          'err=${result.stderr}');
      return result.exitCode;
    } finally {
      await scriptFile.delete().catchError((_) => scriptFile);
    }
  }

  static Future<InstallStep> _installGitWindowsCerts(List<int> pemBytes) async {
    // Git for Windows stores its bundle at:
    //   C:\Program Files\Git\usr\ssl\certs\ca-bundle.crt
    final candidates = [
      r'C:\Program Files\Git\usr\ssl\certs\ca-bundle.crt',
      r'C:\Program Files (x86)\Git\usr\ssl\certs\ca-bundle.crt',
    ];

    for (final path in candidates) {
      final f = File(path);
      if (await f.exists()) {
        final result = await _appendToPemStore(
            pemBytes, [path], 'Git for Windows (ca-bundle.crt)');
        if (result.success) return result;
      }
    }

    return InstallStep(
      name: 'Git for Windows (ca-bundle.crt)',
      success: false,
      note: 'Git for Windows not found at expected paths',
    );
  }

  static Future<InstallStep> _installWindowsNodeExtraCa(List<int> pemBytes) async {
    // Store cert at a stable location and set HKLM env var
    const destDir = r'C:\ProgramData\lux';
    const destPath = r'C:\ProgramData\lux\intercept_ca.pem';

    try {
      final dir = Directory(destDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(destPath).writeAsBytes(pemBytes);

      // Set NODE_EXTRA_CA_CERTS system-wide via registry
      final regResult = await _runWindowsAsAdmin(
        'reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" '
        '/v NODE_EXTRA_CA_CERTS /t REG_SZ /d "$destPath" /f',
        description: 'Setting NODE_EXTRA_CA_CERTS for Node.js/npm',
      );

      return InstallStep(
        name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)',
        success: regResult == 0,
        note: regResult == 0
            ? 'Set NODE_EXTRA_CA_CERTS=$destPath in system environment'
            : 'Registry write failed (exit $regResult)',
      );
    } catch (e) {
      return InstallStep(
        name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)',
        success: false,
        note: 'Error: $e',
      );
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

        // Check if cert is already present (basic dedup)
        final existing = await f.readAsString();
        final pemStr = String.fromCharCodes(pemBytes);
        if (existing.contains(_extractPemBody(pemStr))) {
          return InstallStep(
              name: storeName, success: true, note: 'Already present');
        }

        final raf = await f.open(mode: FileMode.append);
        await raf.writeString('\n# Added by Lux SSL inspection CA\n');
        await raf.writeFrom(pemBytes);
        await raf.close();

        return InstallStep(
            name: storeName, success: true, note: 'Appended to $path');
      } catch (e) {
        debugPrint('Failed to append to $path: $e');
      }
    }
    return InstallStep(
      name: storeName,
      success: false,
      note: 'No writable store found in: ${paths.join(', ')}',
    );
  }

  /// Extracts the base64 body from a PEM string for dedup checking.
  static String _extractPemBody(String pem) {
    final lines = pem.split('\n').where((l) =>
        !l.startsWith('-----') && l.trim().isNotEmpty);
    return lines.join('').substring(0, 32.clamp(0, lines.join('').length));
  }

  /// Installs into Python certifi on both macOS and Windows.
  static Future<List<InstallStep>> _installPythonCertifi(
      List<int> pemBytes) async {
    final steps = <InstallStep>[];

    // Find certifi's cacert.pem via python3 -c "import certifi; print(certifi.where())"
    for (final python in ['python3', 'python', 'python3.11', 'python3.12']) {
      try {
        final result = await Process.run(
            Platform.isWindows ? python : '/usr/bin/env',
            Platform.isWindows
                ? [python, '-c', 'import certifi; print(certifi.where())']
                : [python, '-c', 'import certifi; print(certifi.where())']);
        if (result.exitCode != 0) continue;

        final certifiPath = result.stdout.toString().trim();
        if (certifiPath.isEmpty) continue;

        final step = await _appendToPemStore(
            pemBytes, [certifiPath], 'Python certifi ($python)');
        steps.add(step);
        if (step.success) break; // only need one Python certifi
      } catch (_) {
        continue;
      }
    }

    if (steps.isEmpty) {
      steps.add(InstallStep(
        name: 'Python certifi',
        success: false,
        note: 'Python not found or certifi not installed',
      ));
    }

    return steps;
  }

  /// macOS: writes cert to /etc/ssl/certs/lux_intercept_ca.pem and sets
  /// NODE_EXTRA_CA_CERTS in /etc/launchd.conf so it's picked up system-wide.
  static Future<InstallStep> _installNodeExtraCa(List<int> pemBytes) async {
    const destPath = '/etc/ssl/certs/lux_intercept_ca.pem';

    // Write cert via admin
    final tmp = File('/tmp/lux_node_ca_${DateTime.now().millisecondsSinceEpoch}.pem');
    await tmp.writeAsBytes(pemBytes);

    try {
      final copyExit = await _runMacOSAsAdmin(
        'cp "${tmp.path}" "$destPath" && chmod 644 "$destPath"',
        description: 'Installing CA for Node.js/npm',
      );
      if (copyExit != 0) {
        return InstallStep(
          name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)',
          success: false,
          note: 'Could not write to $destPath',
        );
      }

      // Add to /etc/launchd.conf (macOS system env for all processes)
      const launchdLine = 'setenv NODE_EXTRA_CA_CERTS $destPath';
      final launchdConf = File('/etc/launchd.conf');
      String existing = '';
      try {
        if (await launchdConf.exists()) existing = await launchdConf.readAsString();
      } catch (_) {}

      if (!existing.contains('NODE_EXTRA_CA_CERTS')) {
        await _runMacOSAsAdmin(
          'echo "$launchdLine" >> /etc/launchd.conf',
          description: 'Setting NODE_EXTRA_CA_CERTS in /etc/launchd.conf',
        );
      }

      // Also write to /etc/environment and /etc/profile for interactive shells
      for (final profileFile in [
        '/etc/profile.d/lux_ca.sh',
        '/etc/zshenv',
      ]) {
        try {
          String profileContent = '';
          final pf = File(profileFile);
          if (await pf.exists()) {
            try { profileContent = await pf.readAsString(); } catch (_) {}
          }
          if (!profileContent.contains('NODE_EXTRA_CA_CERTS')) {
            await _runMacOSAsAdmin(
              'echo \'export NODE_EXTRA_CA_CERTS=$destPath\' >> $profileFile',
              description: 'Setting NODE_EXTRA_CA_CERTS in $profileFile',
            );
          }
        } catch (_) {}
      }

      return InstallStep(
        name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)',
        success: true,
        note: 'Cert at $destPath; NODE_EXTRA_CA_CERTS set in launchd.conf',
      );
    } finally {
      await tmp.delete().catchError((_) => tmp);
    }
  }
}

/// Result of a certificate installation attempt.
class InstallResult {
  final bool success;
  final List<InstallStep> steps;
  final String? error;

  const InstallResult({
    required this.success,
    required this.steps,
    this.error,
  });
}

/// Outcome of a single installation step (e.g. "macOS System Keychain").
class InstallStep {
  final String name;
  final bool success;
  final String note;

  const InstallStep({
    required this.name,
    required this.success,
    required this.note,
  });
}
