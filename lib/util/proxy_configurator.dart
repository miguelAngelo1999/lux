import 'dart:io';

import 'package:flutter/foundation.dart';

/// Configures proxy environment variables for CLI tools and desktop apps
/// when Lux connects, and clears them on disconnect.
///
/// NOTE: System proxy (networksetup on macOS, registry on Windows) is already
/// managed by lux_core's sysproxy package. This class handles the things
/// lux_core does NOT do:
///   macOS: launchctl env vars, /etc/zshenv, git config, npm config, Firefox
///   Windows: Machine/User env vars, git config, npm config
///
/// We intentionally do NOT call networksetup here — if lux crashes without
/// calling stop(), the system proxy would stay pointed at 127.0.0.1:1090
/// forever, breaking all internet access.
class ProxyConfigurator {
  static const _noProxy =
      'localhost,127.0.0.1,10.255.0.1,*.local,169.254/16';

  static Future<void> apply(String proxyAddr) async {
    if (Platform.isMacOS) {
      await _applyMacOS(proxyAddr);
    } else if (Platform.isWindows) {
      await _applyWindows(proxyAddr);
    }
    debugPrint('[ProxyConfigurator] Applied proxy: http://$proxyAddr');
  }

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

    // Write admin script to set launchctl env vars and /etc/zshenv.
    // networksetup is intentionally omitted — lux_core handles system proxy.
    final script = File('/tmp/lux_proxy_apply.sh');
    await script.writeAsString(
      '#!/bin/bash\n'
      'PROXY="$httpProxy"\n'
      'NO_PROXY_VAL="$_noProxy"\n'
      '\n'
      'launchctl setenv HTTP_PROXY "\$PROXY" 2>/dev/null || true\n'
      'launchctl setenv HTTPS_PROXY "\$PROXY" 2>/dev/null || true\n'
      'launchctl setenv http_proxy "\$PROXY" 2>/dev/null || true\n'
      'launchctl setenv https_proxy "\$PROXY" 2>/dev/null || true\n'
      'launchctl setenv NO_PROXY "\$NO_PROXY_VAL" 2>/dev/null || true\n'
      'launchctl setenv no_proxy "\$NO_PROXY_VAL" 2>/dev/null || true\n'
      '# NODE_EXTRA_CA_CERTS makes Node.js/Electron apps trust the corporate proxy CA\n'
      '# without disabling certificate verification (safer than NODE_TLS_REJECT_UNAUTHORIZED).\n'
      '# /etc/ssl/cert.pem has the corporate CA appended by the cert installer.\n'
      'launchctl setenv NODE_EXTRA_CA_CERTS /etc/ssl/cert.pem 2>/dev/null || true\n'
      'launchctl setenv CURL_CA_BUNDLE /etc/ssl/cert.pem 2>/dev/null || true\n'
      '\n'
      '# Add bypass domains directly to macOS networksetup for all active services\n'
      'while IFS= read -r SVC; do\n'
      '  networksetup -setproxybypassdomains "\$SVC" localhost 127.0.0.1 10.255.0.1 "*.local" "169.254/16" 2>/dev/null || true\n'
      'done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)\n'
      '\n'
      '\n'
      'LAUNCHD=/etc/launchd.conf\n'
      'touch "\$LAUNCHD" 2>/dev/null || true\n'
      'grep -v "LUX_PROXY" "\$LAUNCHD" > /tmp/lux_launchd_clean.conf 2>/dev/null || true\n'
      'printf "setenv HTTP_PROXY %s # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_launchd_clean.conf\n'
      'printf "setenv HTTPS_PROXY %s # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_launchd_clean.conf\n'
      'printf "setenv http_proxy %s # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_launchd_clean.conf\n'
      'printf "setenv https_proxy %s # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_launchd_clean.conf\n'
      'printf "setenv NO_PROXY %s # LUX_PROXY\\n" "\$NO_PROXY_VAL" >> /tmp/lux_launchd_clean.conf\n'
      'printf "setenv no_proxy %s # LUX_PROXY\\n" "\$NO_PROXY_VAL" >> /tmp/lux_launchd_clean.conf\n'
      'cp /tmp/lux_launchd_clean.conf "\$LAUNCHD" 2>/dev/null || true\n'
      '\n'
      'touch /etc/zshenv 2>/dev/null || true\n'
      'grep -v "LUX_PROXY" /etc/zshenv > /tmp/lux_zshenv_clean 2>/dev/null || true\n'
      'printf "export HTTP_PROXY=\\"%s\\" # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_zshenv_clean\n'
      'printf "export HTTPS_PROXY=\\"%s\\" # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_zshenv_clean\n'
      'printf "export http_proxy=\\"%s\\" # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_zshenv_clean\n'
      'printf "export https_proxy=\\"%s\\" # LUX_PROXY\\n" "\$PROXY" >> /tmp/lux_zshenv_clean\n'
      'printf "export NO_PROXY=\\"%s\\" # LUX_PROXY\\n" "\$NO_PROXY_VAL" >> /tmp/lux_zshenv_clean\n'
      'printf "export no_proxy=\\"%s\\" # LUX_PROXY\\n" "\$NO_PROXY_VAL" >> /tmp/lux_zshenv_clean\n'
      'printf "export CURL_CA_BUNDLE=/etc/ssl/cert.pem # LUX_PROXY\\n" >> /tmp/lux_zshenv_clean\n'
      'printf "export NODE_EXTRA_CA_CERTS=/etc/ssl/cert.pem # LUX_PROXY\\n" >> /tmp/lux_zshenv_clean\n'
      'cp /tmp/lux_zshenv_clean /etc/zshenv 2>/dev/null || true\n'
      'echo "LUX_PROXY_APPLY_OK"\n',
    );
    await _runAdminScript(script, 'Lux needs admin access to configure proxy environment');

    await _setGitProxy(httpProxy);
    await _setNpmProxy(httpProxy);
    await _setFirefoxProxy(host, int.tryParse(port) ?? 1090);
  }

  static Future<void> _clearMacOS() async {
    final script = File('/tmp/lux_proxy_clear.sh');
    await script.writeAsString(
      '#!/bin/bash\n'
      'for VAR in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE; do\n'
      '  launchctl unsetenv "\$VAR" 2>/dev/null || true\n'
      'done\n'
      'grep -v "LUX_PROXY" /etc/launchd.conf > /tmp/lux_launchd_clean.conf 2>/dev/null || true\n'
      'cp /tmp/lux_launchd_clean.conf /etc/launchd.conf 2>/dev/null || true\n'
      'grep -v "LUX_PROXY" /etc/zshenv > /tmp/lux_zshenv_clean 2>/dev/null || true\n'
      'cp /tmp/lux_zshenv_clean /etc/zshenv 2>/dev/null || true\n'
      'echo "LUX_PROXY_CLEAR_OK"\n',
    );
    await _runAdminScript(script, 'Lux needs admin access to clear proxy environment');

    await _clearGitProxy();
    await _clearNpmProxy();
    await _clearFirefoxProxy();
  }

  // ── Admin script runner ───────────────────────────────────────────────────

  static Future<void> _runAdminScript(File script, String prompt) async {
    await Process.run('chmod', ['+x', script.path]);
    // Try sudo -n first (NOPASSWD — instant after first-launch setup)
    final sudoResult = await Process.run('sudo', ['-n', 'bash', script.path]);
    if (sudoResult.exitCode == 0) {
      await script.delete().catchError((_) => script);
      return;
    }
    // Fall back to osascript — macOS shows Touch ID if available, else password
    await Process.run('/usr/bin/osascript', ['-e',
      "do shell script \"bash '${script.path}'\" "
      "with prompt \"$prompt\" "
      "with administrator privileges"]);
    await script.delete().catchError((_) => script);
  }

  // ── Firefox ───────────────────────────────────────────────────────────────

  static Future<void> _setFirefoxProxy(String host, int port) async {
    final home = Platform.environment['HOME'] ?? '';
    final profileBases = [
      '$home/Library/Application Support/Firefox/Profiles',
      '$home/Library/Application Support/Thunderbird/Profiles',
    ];
    final userJs =
        '// Added by Lux proxy configurator — LUX_PROXY\n'
        'user_pref("network.proxy.type", 1);\n'
        'user_pref("network.proxy.http", "$host");\n'
        'user_pref("network.proxy.http_port", $port);\n'
        'user_pref("network.proxy.ssl", "$host");\n'
        'user_pref("network.proxy.ssl_port", $port);\n'
        'user_pref("network.proxy.no_proxies_on", "$_noProxy");\n';
    for (final base in profileBases) {
      final dir = Directory(base);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final f = File('${entry.path}/user.js');
        try {
          String existing = '';
          if (await f.exists()) {
            existing = (await f.readAsString())
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
      await Process.run('git', ['config', '--global', '--unset', 'http.proxy']);
      await Process.run('git', ['config', '--global', '--unset', 'https.proxy']);
    } catch (_) {}
  }

  // ── npm ───────────────────────────────────────────────────────────────────

  static Future<void> _setNpmProxy(String httpProxy) async {
    try {
      await Process.run('npm', ['config', 'set', 'proxy', httpProxy], runInShell: true);
      await Process.run('npm', ['config', 'set', 'https-proxy', httpProxy], runInShell: true);
    } catch (_) {}
  }

  static Future<void> _clearNpmProxy() async {
    try {
      await Process.run('npm', ['config', 'delete', 'proxy'], runInShell: true);
      await Process.run('npm', ['config', 'delete', 'https-proxy'], runInShell: true);
    } catch (_) {}
  }

  // ── Windows ───────────────────────────────────────────────────────────────

  static Future<void> _applyWindows(String proxyAddr) async {
    final httpProxy = 'http://$proxyAddr';
    // Disable Windows "Automatically detect settings" (WPAD) so traffic
    // goes through lux's 127.0.0.1:1090 instead of the corporate PAC/WPAD.
    await _setWindowsAutoDetect(false);
    await _setEnvVarsWindows(httpProxy);
    await _setGitProxy(httpProxy);
    await _setNpmProxy(httpProxy);
  }

  static Future<void> _clearWindows() async {
    // Restore AutoDetect when lux disconnects
    await _setWindowsAutoDetect(true);
    await _clearEnvVarsWindows();
    await _clearGitProxy();
    await _clearNpmProxy();
  }

  /// Enables or disables Windows "Automatically detect settings" (WPAD/PAC).
  static Future<void> _setWindowsAutoDetect(bool enabled) async {
    try {
      final value = enabled ? 1 : 0;
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        'Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" '
            '-Name "AutoDetect" -Value $value -Force',
      ]);
    } catch (_) {}
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
        r'[Environment]::SetEnvironmentVariable("HTTP_PROXY",$null,"Machine");'
            r'[Environment]::SetEnvironmentVariable("HTTPS_PROXY",$null,"Machine");'
            r'[Environment]::SetEnvironmentVariable("NO_PROXY",$null,"Machine")',
      ]);
    } catch (_) {}
    try {
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        r'[Environment]::SetEnvironmentVariable("HTTP_PROXY",$null,"User");'
            r'[Environment]::SetEnvironmentVariable("HTTPS_PROXY",$null,"User");'
            r'[Environment]::SetEnvironmentVariable("NO_PROXY",$null,"User")',
      ]);
    } catch (_) {}
  }
}
