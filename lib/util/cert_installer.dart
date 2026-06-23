import 'dart:io';

import 'package:flutter/foundation.dart';

/// Installs a PEM-encoded CA certificate into the platform's trusted root
/// store and into popular terminal tool stores (curl, git, Node.js, Python)
/// as well as app-bundled cert stores (conda, video editors, etc.).
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

    const certPath = '/tmp/lux_intercept_ca.pem';
    await File(certPath).writeAsBytes(pemBytes);

    try {
      // Build a single admin script for all root-requiring operations.
      // User gets ONE password prompt.
      final adminScript = File('/tmp/lux_cert_install.sh');
      final scriptLines = [
        '#!/bin/bash',
        '# Do NOT use set -e — each step must run independently.',
        '# A failure in one step should not abort the rest.',
        'CERT="$certPath"',
        'ERRORS=""',
        '',
        '# 1. Trust in System Keychain',
        '# Try system-wide first, fall back to login keychain if that fails',
        'if security add-trusted-cert -d -r trustRoot '
            '-k /Library/Keychains/System.keychain "\$CERT" 2>/dev/null; then',
        '  echo "STEP_KEYCHAIN=ok"',
        'elif security add-trusted-cert -r trustRoot "\$CERT" 2>/dev/null; then',
        '  echo "STEP_KEYCHAIN=ok"',
        'else',
        '  # May already be trusted — check before declaring failure',
        r'  FP=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | sed "s/.*=//" | tr -d ":")',
        r'  if security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qi "$FP"; then',
        '    echo "STEP_KEYCHAIN=ok"',
        '  else',
        '    echo "STEP_KEYCHAIN=fail"',
        '  fi',
        'fi',
        '',
        '# 2. Append to system OpenSSL cert stores (curl, wget)',
        'CURL_OK=0',
        'for STORE in /etc/ssl/cert.pem /usr/local/etc/openssl/cert.pem /opt/homebrew/etc/openssl/cert.pem /opt/homebrew/etc/openssl@3/cert.pem /usr/local/etc/openssl@3/cert.pem; do',
        '  if [ -f "\$STORE" ]; then',
        '    if ! grep -qF "BEGIN CERTIFICATE" "\$STORE" 2>/dev/null || ! diff <(openssl x509 -in "\$CERT" -noout -fingerprint 2>/dev/null) <(openssl x509 -in "\$STORE" -noout -fingerprint 2>/dev/null) > /dev/null 2>&1; then',
        '      if ! grep -q "Added by Lux SSL" "\$STORE" 2>/dev/null; then',
        '        echo "" >> "\$STORE" && echo "# Added by Lux SSL inspection CA" >> "\$STORE" && cat "\$CERT" >> "\$STORE" && CURL_OK=1',
        '      else',
        '        CURL_OK=1',
        '      fi',
        '    else',
        '      CURL_OK=1',
        '    fi',
        '  fi',
        'done',
        'echo "STEP_CURL=\$CURL_OK"',
        '',
        '# 3. Node.js NODE_EXTRA_CA_CERTS + curl CURL_CA_BUNDLE',
        'NODE_OK=0',
        'mkdir -p /etc/ssl/certs 2>/dev/null || true',
        'if cp "\$CERT" /etc/ssl/certs/lux_intercept_ca.pem 2>/dev/null; then',
        '  chmod 644 /etc/ssl/certs/lux_intercept_ca.pem 2>/dev/null || true',
        '  NODE_OK=1',
        'fi',
        '',
        'if [ ! -f /etc/launchd.conf ] || ! grep -q NODE_EXTRA_CA_CERTS /etc/launchd.conf 2>/dev/null; then',
        '  echo "setenv NODE_EXTRA_CA_CERTS /etc/ssl/certs/lux_intercept_ca.pem" >> /etc/launchd.conf 2>/dev/null || true',
        'fi',
        '',
        'EXPORT_LINE="export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/lux_intercept_ca.pem"',
        'CURL_LINE="export CURL_CA_BUNDLE=/etc/ssl/cert.pem"',
        'if [ ! -f /etc/zshenv ] || ! grep -q NODE_EXTRA_CA_CERTS /etc/zshenv 2>/dev/null; then',
        '  echo "\$EXPORT_LINE" >> /etc/zshenv 2>/dev/null || true',
        'fi',
        'if [ ! -f /etc/zshenv ] || ! grep -q CURL_CA_BUNDLE /etc/zshenv 2>/dev/null; then',
        '  echo "\$CURL_LINE" >> /etc/zshenv 2>/dev/null || true',
        'fi',
        'mkdir -p /etc/profile.d 2>/dev/null || true',
        'if [ ! -f /etc/profile.d/lux_ca.sh ] || ! grep -q NODE_EXTRA_CA_CERTS /etc/profile.d/lux_ca.sh 2>/dev/null; then',
        '  echo "\$EXPORT_LINE" >> /etc/profile.d/lux_ca.sh 2>/dev/null || true',
        '  echo "\$CURL_LINE" >> /etc/profile.d/lux_ca.sh 2>/dev/null || true',
        'fi',
        'echo "STEP_NODE=\$NODE_OK"',
        '',
        '# 4. Firefox / Thunderbird — NSS cert databases',
        r'CERTUTIL_BIN=$(command -v certutil 2>/dev/null || find /opt/homebrew/bin /usr/local/bin /Applications -name certutil -type f 2>/dev/null | head -1)',
        'NSS_OK=0',
        r'if [ -x "$CERTUTIL_BIN" ]; then',
        r'  for PROF_BASE in "$HOME/Library/Application Support/Firefox/Profiles" "$HOME/Library/Application Support/Thunderbird/Profiles"; do',
        r'    if [ -d "$PROF_BASE" ]; then',
        r'      for DB in "$PROF_BASE"/*/; do',
        r'        if [ -f "${DB}cert9.db" ] || [ -f "${DB}cert8.db" ]; then',
        r'          "$CERTUTIL_BIN" -A -n "Lux SSL Inspection CA" -t "CT,C,C" -i "$CERT" -d "$DB" 2>/dev/null && NSS_OK=1 || true',
        r'        fi',
        r'      done',
        r'    fi',
        r'  done',
        r'fi',
        'echo "STEP_NSS=\$NSS_OK"',
        '',
        'echo "LUX_CERT_INSTALL_OK"',
      ];

      await adminScript.writeAsString(scriptLines.join('\n'));
      await Process.run('chmod', ['+x', adminScript.path]);

      final adminResult = await _runMacOSAdminScript(
          adminScript.path,
          'Lux needs admin access to install the CA certificate');
      await adminScript.delete().catchError((_) => adminScript);

      final adminOut = adminResult.stdout;
      debugPrint('macOS cert admin exit=${adminResult.exitCode} out=$adminOut');

      if (adminResult.exitCode != 0) {
        // User cancelled or osascript itself failed — mark all as failed
        steps.add(InstallStep(
            name: 'macOS System Keychain', success: false,
            note: 'Admin script failed (exit ${adminResult.exitCode}). User may have cancelled.'));
        steps.add(const InstallStep(
            name: 'curl (system OpenSSL)', success: false, note: 'Admin script failed'));
        steps.add(const InstallStep(
            name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)', success: false,
            note: 'Admin script failed'));
        steps.add(const InstallStep(
            name: 'Firefox / Thunderbird (NSS)', success: false,
            note: 'Admin script failed'));
      } else {
        // Parse per-step results from stdout
        final keychainOk = adminOut.contains('STEP_KEYCHAIN=ok');
        final curlOk = adminOut.contains('STEP_CURL=1');
        final nodeOk = adminOut.contains('STEP_NODE=1');
        final nssOk = adminOut.contains('STEP_NSS=1');

        steps.add(InstallStep(
            name: 'macOS System Keychain',
            success: keychainOk,
            note: keychainOk ? 'Trusted system-wide' : 'security command failed — try opening Keychain Access and trusting manually'));
        steps.add(InstallStep(
            name: 'curl (system OpenSSL)',
            success: curlOk,
            note: curlOk ? 'Appended to system cert stores' : 'No system OpenSSL store found'));
        steps.add(InstallStep(
            name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)',
            success: nodeOk,
            note: nodeOk
                ? 'Cert at /etc/ssl/certs/lux_intercept_ca.pem; set in launchd.conf + zshenv'
                : 'Could not write to /etc/ssl/certs'));
        steps.add(InstallStep(
            name: 'Firefox / Thunderbird (NSS)',
            success: nssOk,
            note: nssOk
                ? 'Injected into profile cert databases'
                : 'certutil not found or no Firefox/Thunderbird profiles'));
      }

      // Homebrew openssl@3 — only attempt if the file actually exists
      final brewSslPaths = [
        '/opt/homebrew/etc/openssl@3/cert.pem',
        '/usr/local/etc/openssl@3/cert.pem',
      ];
      final brewSslExists = brewSslPaths.any((p) => File(p).existsSync());
      if (brewSslExists) {
        steps.add(await _appendToPemStore(pemBytes, brewSslPaths, 'Homebrew openssl@3'));
      }

      // Git (Homebrew openssl bundle) — only attempt if file exists
      final gitPaths = [
        '/opt/homebrew/etc/openssl@3/cert.pem',
        '/usr/local/etc/openssl@3/cert.pem',
        '/opt/homebrew/etc/openssl/cert.pem',
        '/usr/local/etc/openssl/cert.pem',
      ];
      final gitPathExists = gitPaths.any((p) => File(p).existsSync());
      if (gitPathExists) {
        steps.add(await _appendToPemStore(pemBytes, gitPaths, 'git (Homebrew bundle)'));
      }

      // Python certifi — only add step if python/certifi is actually found
      final pythonSteps = await _installPythonCertifi(pemBytes);
      if (pythonSteps.any((s) => s.success || !s.note.contains('Python not found'))) {
        steps.addAll(pythonSteps);
      }

      // App-bundled cert stores (only add if something was found)
      final appBundleStep = await _installAppBundledCerts(pemBytes);
      if (appBundleStep != null) steps.add(appBundleStep);
    } finally {
      await File(certPath).delete().catchError((_) => File(certPath));
    }

    final anySuccess = steps.any((s) => s.success);
    return InstallResult(
      success: anySuccess,
      steps: steps,
      error: anySuccess ? null : 'All installation steps failed',
    );
  }

  static Future<({int exitCode, String stdout})> _runMacOSAdminScript(
      String scriptPath, String prompt) async {
    // Try sudo -n first (NOPASSWD — instant, no prompt after first-launch setup)
    final sudoResult = await Process.run('sudo', ['-n', 'bash', scriptPath]);
    if (sudoResult.exitCode == 0) {
      return (exitCode: 0, stdout: sudoResult.stdout.toString());
    }
    // Fall back to osascript — macOS shows Touch ID if available, else password
    final result = await Process.run('/usr/bin/osascript', ['-e',
      "do shell script \"bash '$scriptPath'\" with prompt "
      "\"$prompt\" "
      "with administrator privileges"]);
    debugPrint('cert admin (osascript): exit=${result.exitCode}');
    return (exitCode: result.exitCode, stdout: result.stdout.toString());
  }

  static Future<InstallResult> _installWindows(List<int> pemBytes) async {
    final steps = <InstallStep>[];

    // Use C:\Windows\Temp (accessible by elevated processes) instead of user temp
    // which may be deleted before the elevated bat file runs
    const tmpPath = r'C:\Windows\Temp\lux_intercept_ca.pem';
    final tmpPem = File(tmpPath);
    await tmpPem.writeAsBytes(pemBytes);

    try {
      // Windows Trusted Root store (all users)
      final certutilResult = await _runWindowsAsAdmin(
        'certutil -addstore -f Root "${tmpPem.path}"',
      );
      steps.add(InstallStep(
        name: 'Windows Trusted Root (certutil)',
        success: certutilResult == 0,
        note: certutilResult == 0
            ? 'Installed to LocalMachine\\Root'
            : 'certutil exit code: $certutilResult',
      ));

      // curl on Windows uses Windows cert store
      steps.add(InstallStep(
        name: 'curl (uses Windows cert store)',
        success: certutilResult == 0,
        note: certutilResult == 0
            ? 'Covered by certutil install'
            : 'Skipped — certutil failed',
      ));

      // Git for Windows
      steps.add(await _installGitWindowsCerts(pemBytes));

      // App-bundled cert stores (only add if something was found)
      final appBundleStep = await _installAppBundledCerts(pemBytes);
      if (appBundleStep != null) steps.add(appBundleStep);

      // Node.js / npm
      steps.add(await _installWindowsNodeExtraCa(pemBytes));

      // Python certifi
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

  static Future<int> _runWindowsAsAdmin(String cmd) async {
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
      // Give the elevated process time to finish (Start-Process -Wait doesn't
      // block when crossing elevation boundary on "never notify" UAC setting)
      await Future.delayed(const Duration(seconds: 3));
      debugPrint('Windows admin exit=${result.exitCode} err=${result.stderr}');
      return result.exitCode;
    } finally {
      await scriptFile.delete().catchError((_) => scriptFile);
    }
  }

  static Future<InstallStep> _installGitWindowsCerts(List<int> pemBytes) async {
    final candidates = [
      r'C:\Program Files\Git\usr\ssl\certs\ca-bundle.crt',
      r'C:\Program Files (x86)\Git\usr\ssl\certs\ca-bundle.crt',
    ];

    for (final path in candidates) {
      if (await File(path).exists()) {
        final result = await _appendToPemStore(
            pemBytes, [path], 'Git for Windows (ca-bundle.crt)');
        if (result.success) return result;
      }
    }

    return const InstallStep(
      name: 'Git for Windows (ca-bundle.crt)',
      success: false,
      note: 'Git for Windows not found',
    );
  }

  static Future<InstallStep> _installWindowsNodeExtraCa(List<int> pemBytes) async {
    const destDir = r'C:\ProgramData\lux';
    const destPath = r'C:\ProgramData\lux\intercept_ca.pem';

    try {
      final dir = Directory(destDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(destPath).writeAsBytes(pemBytes);

      final regResult = await _runWindowsAsAdmin(
        'reg add "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" '
        '/v NODE_EXTRA_CA_CERTS /t REG_SZ /d "$destPath" /f',
      );

      return InstallStep(
        name: 'Node.js / npm (NODE_EXTRA_CA_CERTS)',
        success: regResult == 0,
        note: regResult == 0
            ? 'Set NODE_EXTRA_CA_CERTS=$destPath'
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

  // ── App-bundled cert stores ──────────────────────────────────────────────

  /// Scans for applications that ship their own CA cert bundles
  /// and appends the cert. Reports generically — no app names in the UI.
  static Future<InstallStep?> _installAppBundledCerts(List<int> pemBytes) async {
    final candidates = <String>[];

    if (Platform.isWindows) {
      final programData = Platform.environment['PROGRAMDATA'] ?? r'C:\ProgramData';
      final programFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
      final userProfile = Platform.environment['USERPROFILE'] ?? r'C:\Users\user';

      // Video editors
      candidates.addAll([
        '$programData\\Blackmagic Design\\DaVinci Resolve\\curl-ca-bundle.crt',
        '$programData\\Blackmagic Design\\DaVinci Resolve\\cacert.pem',
        '$programData\\Blackmagic Design\\DaVinci Resolve\\ssl\\cert.pem',
      ]);

      // Anaconda / Miniconda
      candidates.addAll([
        '$userProfile\\Anaconda3\\Library\\ssl\\cacert.pem',
        '$userProfile\\Miniconda3\\Library\\ssl\\cacert.pem',
        '$userProfile\\anaconda3\\Library\\ssl\\cacert.pem',
        '$userProfile\\miniconda3\\Library\\ssl\\cacert.pem',
        '$programData\\Anaconda3\\Library\\ssl\\cacert.pem',
        '$programData\\Miniconda3\\Library\\ssl\\cacert.pem',
        '$programFiles\\Anaconda3\\Library\\ssl\\cacert.pem',
        '$programFiles\\Miniconda3\\Library\\ssl\\cacert.pem',
      ]);

      // Ruby
      candidates.addAll([
        '$programFiles\\Ruby32-x64\\ssl\\cert.pem',
        '$programFiles\\Ruby31-x64\\ssl\\cert.pem',
        '$programFiles\\Ruby33-x64\\ssl\\cert.pem',
      ]);

      // Java (PEM bundles some vendors ship alongside cacerts keystore)
      candidates.addAll([
        '$programFiles\\Java\\jre\\lib\\security\\cacerts.pem',
        '$programFiles\\Eclipse Adoptium\\jdk-21\\lib\\security\\cacerts.pem',
      ]);
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '/Users/user';

      // Video editors
      candidates.addAll([
        '/Library/Application Support/Blackmagic Design/DaVinci Resolve/curl-ca-bundle.crt',
        '/Library/Application Support/Blackmagic Design/DaVinci Resolve/cacert.pem',
      ]);

      // Anaconda / Miniconda
      candidates.addAll([
        '$home/anaconda3/ssl/cacert.pem',
        '$home/miniconda3/ssl/cacert.pem',
        '$home/anaconda3/lib/python3.11/site-packages/certifi/cacert.pem',
        '$home/anaconda3/lib/python3.12/site-packages/certifi/cacert.pem',
        '$home/miniconda3/lib/python3.11/site-packages/certifi/cacert.pem',
        '$home/miniconda3/lib/python3.12/site-packages/certifi/cacert.pem',
        '/opt/anaconda3/ssl/cacert.pem',
        '/opt/miniconda3/ssl/cacert.pem',
        '/opt/homebrew/anaconda3/ssl/cacert.pem',
      ]);

      // Homebrew Ruby
      candidates.addAll([
        '/opt/homebrew/opt/ruby/etc/openssl/cert.pem',
        '/usr/local/opt/ruby/etc/openssl/cert.pem',
      ]);

      // Java (Homebrew / sdkman)
      candidates.addAll([
        '/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home/lib/security/cacerts.pem',
        '$home/.sdkman/candidates/java/current/lib/security/cacerts.pem',
      ]);
    }

    int patched = 0;
    for (final path in candidates) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;

        final existing = await f.readAsString();
        final pemStr = String.fromCharCodes(pemBytes);
        if (existing.contains(_extractPemBody(pemStr))) {
          patched++; // Already present counts as success
          continue;
        }

        final raf = await f.open(mode: FileMode.append);
        await raf.writeString('\n# Added by Lux SSL inspection CA\n');
        await raf.writeFrom(pemBytes);
        await raf.close();
        patched++;
      } catch (e) {
        debugPrint('App bundle cert write failed for $path: $e');
      }
    }

    if (patched > 0) {
      return InstallStep(
        name: 'App cert bundles',
        success: true,
        note: 'Patched $patched app-bundled cert store${patched > 1 ? 's' : ''}',
      );
    }
    // Nothing found — return null so callers can skip this step silently
    return null;
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
        if (existing.contains(_extractPemBody(pemStr))) {
          return InstallStep(
              name: storeName, success: true, note: 'Already present in $path');
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

  /// Extracts 32 chars of base64 body from PEM for dedup checking.
  static String _extractPemBody(String pem) {
    final body = pem
        .split('\n')
        .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
        .join('');
    return body.length > 32 ? body.substring(0, 32) : body;
  }

  /// Finds Python certifi's cacert.pem and appends the cert.
  static Future<List<InstallStep>> _installPythonCertifi(
      List<int> pemBytes) async {
    for (final python in ['python3', 'python', 'python3.12', 'python3.11']) {
      try {
        final result = await Process.run(
            Platform.isWindows ? python : '/usr/bin/env',
            [python, '-c', 'import certifi; print(certifi.where())']);
        if (result.exitCode != 0) continue;

        final certifiPath = result.stdout.toString().trim();
        if (certifiPath.isEmpty) continue;

        final step = await _appendToPemStore(
            pemBytes, [certifiPath], 'Python certifi ($python)');
        if (step.success) return [step];
      } catch (_) {
        continue;
      }
    }

    return [const InstallStep(
      name: 'Python certifi',
      success: false,
      note: 'Python not found or certifi not installed',
    )];
  }
}

/// Result of a full certificate installation attempt.
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

/// Outcome of a single installation step.
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
