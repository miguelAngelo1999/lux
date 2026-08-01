import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lux/const/const.dart';
import 'package:lux/util/app_log.dart';

/// Configures proxy environment variables for CLI tools and desktop apps.
/// macOS: calls static root-owned scripts with proxy addr as argument.
/// Scripts live in /Library/PrivilegedHelperTools/com.github.igoogolx.lux/
/// and are owned by root:wheel — never written at runtime.
class ProxyConfigurator {
  static const _noProxy = 'localhost,127.0.0.1,10.255.0.1,*.local,169.254/16';
  static const _helperDir = '/Library/PrivilegedHelperTools/com.github.igoogolx.lux';

  static Future<void> apply(String proxyAddr) async {
    appLog('PROXY-CFG', 'applying proxy: $proxyAddr');
    if (Platform.isMacOS) {
      // Guard: don't overwrite HTTP_PROXY if it's already pointing at an
      // upstream proxy (i.e. not a Lux localhost address). This prevents Lux
      // from clobbering tools like Preproxy that set HTTP_PROXY to their own
      // upstream address and read the env var to find it again.
      final existing = await _getUserLaunchctlEnv('HTTP_PROXY');
      if (existing != null && existing.isNotEmpty) {
        final uri = Uri.tryParse(existing);
        final host = uri?.host ?? '';
        final isLux = host == '127.0.0.1' || host == 'localhost';
        if (!isLux) {
          appLog('PROXY-CFG',
              'HTTP_PROXY already set to $existing (non-localhost) — skipping apply to avoid clobbering upstream');
          return;
        }
      }
      await _applyMacOS(proxyAddr);
    } else if (Platform.isWindows) {
      await _applyWindows(proxyAddr);
    }
    appLog('PROXY-CFG', 'apply complete');
  }

  /// Read a single env var from the *user* launchd session (not root).
  static Future<String?> _getUserLaunchctlEnv(String name) async {
    try {
      final result = await Process.run('launchctl', ['getenv', name],
          runInShell: false)
          .timeout(const Duration(seconds: 2));
      final val = (result.stdout as String).trim();
      return val.isEmpty ? null : val;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    appLog('PROXY-CFG', 'clearing proxy settings');
    if (Platform.isMacOS) await _clearMacOS();
    else if (Platform.isWindows) await _clearWindows();
    appLog('PROXY-CFG', 'clear complete');
  }

  // ── macOS ──────────────────────────────────────────────────────────────

  static Future<void> _applyMacOS(String proxyAddr) async {
    final parts = proxyAddr.split(':');
    final host = parts[0];
    final port = parts.length > 1 ? parts[1] : '1090';

    // Call static root-owned script with proxy addr as the sole argument.
    // no_proxy is hardcoded in the script — single arg matches sudoers wildcard.
    // Sudoers: NOPASSWD: /bin/bash .../lux_proxy_apply.sh *
    await _runAdminCommand(
      ['/bin/bash', '$_helperDir/lux_proxy_apply.sh', proxyAddr],
      'Lux needs admin access to configure proxy environment',
    );

    await _setGitProxy('http://$proxyAddr');
    await _setNpmProxy('http://$proxyAddr');
    await _setFirefoxProxy(host, int.tryParse(port) ?? 1090);
  }

  static Future<void> _clearMacOS() async {
    // Call static root-owned script — no arguments needed.
    // Sudoers: NOPASSWD: /bin/bash .../lux_proxy_clear.sh
    await _runAdminCommand(
      ['/bin/bash', '$_helperDir/lux_proxy_clear.sh'],
      'Lux needs admin access to clear proxy environment',
    );

    await _clearGitProxy();
    await _clearNpmProxy();
    await _clearFirefoxProxy();
  }

  // ── Admin runner ───────────────────────────────────────────────────────

  static Future<void> _runAdminCommand(List<String> cmd, String prompt) async {
    appLog('PROXY-CFG', 'sudo -n ${cmd.join(' ')}');
    // Try sudo -n first — matches NOPASSWD rule exactly.
    final sudoResult = await Process.run(
        'sudo', ['-n', ...cmd], runInShell: false);
    if (sudoResult.exitCode == 0) {
      appLog('PROXY-CFG', 'sudo -n succeeded');
      return;
    }
    appLog('PROXY-CFG', 'sudo -n failed (exit ${sudoResult.exitCode}) — falling back to osascript (Touch ID)');
    // Fall back to osascript (Touch ID if pam_tid configured, else password)
    final shellCmd = cmd.map((a) => "'$a'").join(' ');
    await Process.run('/usr/bin/osascript', ['-e',
      'do shell script "$shellCmd" '
      'with prompt "$prompt" '
      'with administrator privileges',
    ]);
  }

  // ── Firefox ────────────────────────────────────────────────────────────

  static Future<void> _setFirefoxProxy(String host, int port) async {
    final home = Platform.environment['HOME'] ?? '';
    final userJs =
        '// LUX_PROXY\nuser_pref("network.proxy.type", 1);\n'
        'user_pref("network.proxy.http", "$host");\n'
        'user_pref("network.proxy.http_port", $port);\n'
        'user_pref("network.proxy.ssl", "$host");\n'
        'user_pref("network.proxy.ssl_port", $port);\n'
        'user_pref("network.proxy.no_proxies_on", "$_noProxy");\n';
    for (final base in [
      '$home/Library/Application Support/Firefox/Profiles',
      '$home/Library/Application Support/Thunderbird/Profiles',
    ]) {
      final dir = Directory(base);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final f = File('${entry.path}/user.js');
        try {
          final existing = await f.exists()
              ? (await f.readAsString()).split('\n').where((l) => !l.contains('LUX_PROXY')).join('\n')
              : '';
          await f.writeAsString('$existing\n$userJs');
        } catch (_) {}
      }
    }
  }

  static Future<void> _clearFirefoxProxy() async {
    final home = Platform.environment['HOME'] ?? '';
    for (final base in [
      '$home/Library/Application Support/Firefox/Profiles',
      '$home/Library/Application Support/Thunderbird/Profiles',
    ]) {
      final dir = Directory(base);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final f = File('${entry.path}/user.js');
        try {
          if (!await f.exists()) continue;
          final lines = (await f.readAsString()).split('\n').where((l) => !l.contains('LUX_PROXY')).join('\n');
          await f.writeAsString(lines);
        } catch (_) {}
      }
    }
  }

  // ── Git ────────────────────────────────────────────────────────────────

  static Future<void> _setGitProxy(String p) async {
    try {
      await Process.run('git', ['config', '--global', 'http.proxy', p]);
      await Process.run('git', ['config', '--global', 'https.proxy', p]);
    } catch (_) {}
  }

  static Future<void> _clearGitProxy() async {
    try {
      await Process.run('git', ['config', '--global', '--unset', 'http.proxy']);
      await Process.run('git', ['config', '--global', '--unset', 'https.proxy']);
    } catch (_) {}
  }

  // ── npm ────────────────────────────────────────────────────────────────

  static Future<void> _setNpmProxy(String p) async {
    try {
      await Process.run('npm', ['config', 'set', 'proxy', p], runInShell: true);
      await Process.run('npm', ['config', 'set', 'https-proxy', p], runInShell: true);
    } catch (_) {}
  }

  static Future<void> _clearNpmProxy() async {
    try {
      await Process.run('npm', ['config', 'delete', 'proxy'], runInShell: true);
      await Process.run('npm', ['config', 'delete', 'https-proxy'], runInShell: true);
    } catch (_) {}
  }

  // ── Windows ────────────────────────────────────────────────────────────

  static Future<void> _applyWindows(String proxyAddr) async {
    final p = 'http://$proxyAddr';
    await _setWindowsAutoDetect(false);
    await _setEnvVarsWindows(p);
    await _setGitProxy(p);
    await _setNpmProxy(p);
  }

  static Future<void> _clearWindows() async {
    await _setWindowsAutoDetect(true);
    await _clearEnvVarsWindows();
    await _clearGitProxy();
    await _clearNpmProxy();
  }

  static Future<void> _setWindowsAutoDetect(bool enabled) async {
    try {
      await Process.run('powershell.exe', ['-noprofile', '-NonInteractive', '-command',
        'Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" -Name "AutoDetect" -Value ${enabled ? 1 : 0} -Force']);
    } catch (_) {}
  }

  static Future<void> _setEnvVarsWindows(String p) async {
    for (final scope in ['Machine', 'User']) {
      try {
        await Process.run('powershell.exe', ['-noprofile', '-NonInteractive', '-command',
          '[Environment]::SetEnvironmentVariable("HTTP_PROXY","$p","$scope");'
          '[Environment]::SetEnvironmentVariable("HTTPS_PROXY","$p","$scope");'
          '[Environment]::SetEnvironmentVariable("NO_PROXY","$_noProxy","$scope")']);
      } catch (_) {}
    }
  }

  static Future<void> _clearEnvVarsWindows() async {
    for (final scope in ['Machine', 'User']) {
      try {
        await Process.run('powershell.exe', ['-noprofile', '-NonInteractive', '-command',
          r'[Environment]::SetEnvironmentVariable("HTTP_PROXY",$null,"' + scope + r'");'
          r'[Environment]::SetEnvironmentVariable("HTTPS_PROXY",$null,"' + scope + r'");'
          r'[Environment]::SetEnvironmentVariable("NO_PROXY",$null,"' + scope + r'")']);
      } catch (_) {}
    }
  }
}
