import 'dart:io';

import 'package:flutter/foundation.dart';

/// Configures system-wide proxy settings for CLI tools and desktop apps
/// when Lux connects, and clears them on disconnect.
///
/// macOS sets:
/// - System proxy via networksetup (HTTP + HTTPS)
/// - launchctl setenv HTTP_PROXY / HTTPS_PROXY / NO_PROXY (GUI apps)
/// - /etc/launchd.conf (persistent across reboots)
/// - git http.proxy / https.proxy (global)
/// - npm proxy / https-proxy
/// - Firefox user.js proxy prefs
///
/// Windows sets:
/// - HTTP_PROXY / HTTPS_PROXY / NO_PROXY env vars (Machine + User scope)
/// - git http.proxy / https.proxy (global)
/// - npm proxy / https-proxy
class ProxyConfigurator {
  static const _noProxy =
      'localhost,127.0.0.1,10.255.0.1,*.local,169.254/16';

  /// Apply proxy settings for all CLI tools and apps.
  static Future<void> apply(String proxyAddr) async {
    if (Platform.isMacOS) {
      await _applyMacOS(proxyAddr);
    } else if (Platform.isWindows) {
      await _applyWindows(proxyAddr);
    }
    debugPrint('[ProxyConfigurator] Applied proxy: http://$proxyAddr');
  }

  /// Clear all proxy settings.
  static Future<void> clear() async {
    if (Platform.isMacOS) {
      await _clearMacOS();
    } else if (Platform.isWindows) {
      await _clearWindows();
    }
    debugPrint('[ProxyConfigurator] Cleared proxy settings');
  }

  // ── macOS ─────────────────────────────────────────────────────────────────

  static Future<void> _applyMacOS(String proxyAddr) async {
    final parts = proxyAddr.split(':');
    final host = parts[0];
    final port = parts.length > 1 ? parts[1] : '1090';
    final httpProxy = 'http://$proxyAddr';

    // Admin script for system-level changes (networksetup, launchctl, /etc files)
    final adminScript = File('/tmp/lux_proxy_apply.sh');
    await adminScript.writeAsString('''
#!/bin/bash
HOST="$host"
PORT="$port"
PROXY="$httpProxy"
NO_PROXY_VAL="$_noProxy"

# 1. System proxy via networksetup for all network services
while IFS= read -r SVC; do
  [[ -z "\$SVC" || "\$SVC" == *"An asterisk"* ]] && continue
  networksetup -setwebproxy "\$SVC" "\$HOST" "\$PORT" off 2>/dev/null || true
  networksetup -setsecurewebproxy "\$SVC" "\$HOST" "\$PORT" off 2>/dev/null || true
  networksetup -setproxybypassdomains "\$SVC" localhost 127.0.0.1 10.255.0.1 "*.local" 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

# 2. launchctl setenv for running GUI apps (immediate effect)
launchctl setenv HTTP_PROXY "\$PROXY" 2>/dev/null || true
launchctl setenv HTTPS_PROXY "\$PROXY" 2>/dev/null || true
launchctl setenv http_proxy "\$PROXY" 2>/dev/null || true
launchctl setenv https_proxy "\$PROXY" 2>/dev/null || true
launchctl setenv NO_PROXY "\$NO_PROXY_VAL" 2>/dev/null || true
launchctl setenv no_proxy "\$NO_PROXY_VAL" 2>/dev/null || true

# 3. /etc/launchd.conf persistence
LAUNCHD=/etc/launchd.conf
touch "\$LAUNCHD" 2>/dev/null || true
grep -v "LUX_PROXY" "\$LAUNCHD" > /tmp/lux_launchd_clean.conf 2>/dev/null || true
printf 'setenv HTTP_PROXY %s # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_launchd_clean.conf
printf 'setenv HTTPS_PROXY %s # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_launchd_clean.conf
printf 'setenv http_proxy %s # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_launchd_clean.conf
printf 'setenv https_proxy %s # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_launchd_clean.conf
printf 'setenv NO_PROXY %s # LUX_PROXY\\n' "\$NO_PROXY_VAL" >> /tmp/lux_launchd_clean.conf
printf 'setenv no_proxy %s # LUX_PROXY\\n' "\$NO_PROXY_VAL" >> /tmp/lux_launchd_clean.conf
cp /tmp/lux_launchd_clean.conf "\$LAUNCHD" 2>/dev/null || true

# 4. /etc/zshenv for new terminals
touch /etc/zshenv 2>/dev/null || true
grep -v "LUX_PROXY" /etc/zshenv > /tmp/lux_zshenv_clean 2>/dev/null || true
printf 'export HTTP_PROXY="%s"   # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_zshenv_clean
printf 'export HTTPS_PROXY="%s"  # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_zshenv_clean
printf 'export http_proxy="%s"   # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_zshenv_clean
printf 'export https_proxy="%s"  # LUX_PROXY\\n' "\$PROXY" >> /tmp/lux_zshenv_clean
printf 'export NO_PROXY="%s"     # LUX_PROXY\\n' "\$NO_PROXY_VAL" >> /tmp/lux_zshenv_clean
printf 'export no_proxy="%s"     # LUX_PROXY\\n' "\$NO_PROXY_VAL" >> /tmp/lux_zshenv_clean
printf 'export CURL_CA_BUNDLE=/etc/ssl/cert.pem  # LUX_PROXY\\n' >> /tmp/lux_zshenv_clean
cp /tmp/lux_zshenv_clean /etc/zshenv 2>/dev/null || true

echo "LUX_PROXY_APPLY_OK"
''');

    await Process.run('chmod', ['+x', adminScript.path]);
    // Run with admin privileges via osascript
    await Process.run('/usr/bin/osascript', ['-e',
      "do shell script \"bash '${adminScript.path}'\" "
      "with prompt \"Lux needs admin access to configure system proxy\" "
      "with administrator privileges"]);
    await adminScript.delete().catchError((_) => adminScript);

    // User-level — no admin needed
    await _setGitProxy(httpProxy);
    await _setNpmProxy(httpProxy);
    await _setFirefoxProxy(host, int.tryParse(port) ?? 1090);
  }

  static Future<void> _clearMacOS() async {
    final adminScript = File('/tmp/lux_proxy_clear.sh');
    await adminScript.writeAsString('''
#!/bin/bash

# 1. Clear system proxy via networksetup
while IFS= read -r SVC; do
  [[ -z "\$SVC" || "\$SVC" == *"An asterisk"* ]] && continue
  networksetup -setwebproxystate "\$SVC" off 2>/dev/null || true
  networksetup -setsecurewebproxystate "\$SVC" off 2>/dev/null || true
done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

# 2. Clear launchctl env vars
for VAR in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy; do
  launchctl unsetenv "\$VAR" 2>/dev/null || true
done

# 3. Remove from /etc/launchd.conf
grep -v "LUX_PROXY" /etc/launchd.conf > /tmp/lux_launchd_clean.conf 2>/dev/null || true
cp /tmp/lux_launchd_clean.conf /etc/launchd.conf 2>/dev/null || true

# 4. Remove from /etc/zshenv
grep -v "LUX_PROXY" /etc/zshenv > /tmp/lux_zshenv_clean 2>/dev/null || true
cp /tmp/lux_zshenv_clean /etc/zshenv 2>/dev/null || true

echo "LUX_PROXY_CLEAR_OK"
''');

    await Process.run('chmod', ['+x', adminScript.path]);
    await Process.run('/usr/bin/osascript', ['-e',
      "do shell script \"bash '${adminScript.path}'\" "
      "with prompt \"Lux needs admin access to clear system proxy\" "
      "with administrator privileges"]);
    await adminScript.delete().catchError((_) => adminScript);

    await _clearGitProxy();
    await _clearNpmProxy();
    await _clearFirefoxProxy();
  }

  // ── Firefox ───────────────────────────────────────────────────────────────

  static Future<void> _setFirefoxProxy(String host, int port) async {
    final home = Platform.environment['HOME'] ?? '';
    final profileBases = [
      '$home/Library/Application Support/Firefox/Profiles',
      '$home/Library/Application Support/Thunderbird/Profiles',
    ];
    final userJs = '''
// Added by Lux proxy configurator — LUX_PROXY
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "$host");
user_pref("network.proxy.http_port", $port);
user_pref("network.proxy.ssl", "$host");
user_pref("network.proxy.ssl_port", $port);
user_pref("network.proxy.no_proxies_on", "$_noProxy");
''';
    for (final base in profileBases) {
      final dir = Directory(base);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final f = File('${entry.path}/user.js');
        try {
          // Remove old Lux lines, append new
          String existing = '';
          if (await f.exists()) {
            existing = await f.readAsString();
            existing = existing
                .split('\n')
                .where((l) => !l.contains('LUX_PROXY'))
                .join('\n');
          }
          await f.writeAsString('$existing\n$userJs');
        } catch (_) {}
      }
    }
  }

  static Future<void> _clearFirefoxProxy() async {
    final home = Platform.environment['HOME'] ?? '';
    final profileBases = [
      '$home/Library/Application Support/Firefox/Profiles',
      '$home/Library/Application Support/Thunderbird/Profiles',
    ];
    for (final base in profileBases) {
      final dir = Directory(base);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final f = File('${entry.path}/user.js');
        try {
          if (!await f.exists()) continue;
          final lines = (await f.readAsString())
              .split('\n')
              .where((l) => !l.contains('LUX_PROXY'))
              .join('\n');
          await f.writeAsString(lines);
        } catch (_) {}
      }
    }
  }

  // ── Git ───────────────────────────────────────────────────────────────────

  static Future<void> _setGitProxy(String httpProxy) async {
    try {
      await Process.run('git', ['config', '--global', 'http.proxy', httpProxy]);
      await Process.run('git', ['config', '--global', 'https.proxy', httpProxy]);
    } catch (_) {}
  }

  static Future<void> _clearGitProxy() async {
    try {
      await Process.run(
          'git', ['config', '--global', '--unset', 'http.proxy']);
      await Process.run(
          'git', ['config', '--global', '--unset', 'https.proxy']);
    } catch (_) {}
  }

  // ── npm ───────────────────────────────────────────────────────────────────

  static Future<void> _setNpmProxy(String httpProxy) async {
    try {
      await Process.run('npm', ['config', 'set', 'proxy', httpProxy],
          runInShell: true);
      await Process.run('npm', ['config', 'set', 'https-proxy', httpProxy],
          runInShell: true);
    } catch (_) {}
  }

  static Future<void> _clearNpmProxy() async {
    try {
      await Process.run('npm', ['config', 'delete', 'proxy'],
          runInShell: true);
      await Process.run('npm', ['config', 'delete', 'https-proxy'],
          runInShell: true);
    } catch (_) {}
  }

  // ── Windows ───────────────────────────────────────────────────────────────

  static Future<void> _applyWindows(String proxyAddr) async {
    final httpProxy = 'http://$proxyAddr';
    await _setEnvVarsWindows(httpProxy);
    await _setGitProxy(httpProxy);
    await _setNpmProxy(httpProxy);
  }

  static Future<void> _clearWindows() async {
    await _clearEnvVarsWindows();
    await _clearGitProxy();
    await _clearNpmProxy();
  }

  static Future<void> _setEnvVarsWindows(String httpProxy) async {
    try {
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '[Environment]::SetEnvironmentVariable("HTTP_PROXY","$httpProxy","Machine");'
            '[Environment]::SetEnvironmentVariable("HTTPS_PROXY","$httpProxy","Machine");'
            '[Environment]::SetEnvironmentVariable("NO_PROXY","$_noProxy","Machine")',
      ]);
    } catch (_) {}
    try {
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '[Environment]::SetEnvironmentVariable("HTTP_PROXY","$httpProxy","User");'
            '[Environment]::SetEnvironmentVariable("HTTPS_PROXY","$httpProxy","User");'
            '[Environment]::SetEnvironmentVariable("NO_PROXY","$_noProxy","User")',
      ]);
    } catch (_) {}
  }

  static Future<void> _clearEnvVarsWindows() async {
    try {
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '[Environment]::SetEnvironmentVariable("HTTP_PROXY",\$null,"Machine");'
            '[Environment]::SetEnvironmentVariable("HTTPS_PROXY",\$null,"Machine");'
            '[Environment]::SetEnvironmentVariable("NO_PROXY",\$null,"Machine")',
      ]);
    } catch (_) {}
    try {
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '[Environment]::SetEnvironmentVariable("HTTP_PROXY",\$null,"User");'
            '[Environment]::SetEnvironmentVariable("HTTPS_PROXY",\$null,"User");'
            '[Environment]::SetEnvironmentVariable("NO_PROXY",\$null,"User")',
      ]);
    } catch (_) {}
  }
}
