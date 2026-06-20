import 'dart:io';

import 'package:flutter/foundation.dart';

/// Configures system-wide proxy settings for CLI tools and desktop apps
/// when Lux connects, and clears them on disconnect.
///
/// Sets:
/// - HTTP_PROXY / HTTPS_PROXY / NO_PROXY environment variables (Machine scope)
/// - git http.proxy / https.proxy (global)
/// - npm proxy / https-proxy
///
/// All Electron apps (Signal, VS Code, Slack, etc.) automatically respect
/// HTTP_PROXY/HTTPS_PROXY env vars, so no per-app config needed.
class ProxyConfigurator {
  static const _noProxy = 'localhost,127.0.0.1,10.*,192.168.*,*.local';

  /// Apply proxy settings for all CLI tools and apps.
  /// Called when Lux connects (starts proxying).
  static Future<void> apply(String proxyAddr) async {
    if (!Platform.isWindows) return;

    final httpProxy = 'http://$proxyAddr';

    // 1. Set Machine-level environment variables (requires elevation)
    //    Falls back to User-level if elevation fails.
    await _setEnvVars(httpProxy);

    // 2. Git global proxy
    await _setGitProxy(httpProxy);

    // 3. npm proxy
    await _setNpmProxy(httpProxy);

    debugPrint('[ProxyConfigurator] Applied proxy: $httpProxy');
  }

  /// Clear all proxy settings.
  /// Called when Lux disconnects (stops proxying).
  static Future<void> clear() async {
    if (!Platform.isWindows) return;

    // 1. Clear environment variables
    await _clearEnvVars();

    // 2. Clear git proxy
    await _clearGitProxy();

    // 3. Clear npm proxy
    await _clearNpmProxy();

    debugPrint('[ProxyConfigurator] Cleared proxy settings');
  }

  // ── Environment Variables ─────────────────────────────────────────────────

  static Future<void> _setEnvVars(String httpProxy) async {
    try {
      // Try Machine scope first (needs elevation — will work when running elevated)
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '[Environment]::SetEnvironmentVariable("HTTP_PROXY","$httpProxy","Machine");'
        '[Environment]::SetEnvironmentVariable("HTTPS_PROXY","$httpProxy","Machine");'
        '[Environment]::SetEnvironmentVariable("NO_PROXY","$_noProxy","Machine")',
      ]);
    } catch (_) {}

    // Always set User scope as well (no elevation needed, immediate effect for new processes)
    try {
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '[Environment]::SetEnvironmentVariable("HTTP_PROXY","$httpProxy","User");'
        '[Environment]::SetEnvironmentVariable("HTTPS_PROXY","$httpProxy","User");'
        '[Environment]::SetEnvironmentVariable("NO_PROXY","$_noProxy","User")',
      ]);
    } catch (_) {}
  }

  static Future<void> _clearEnvVars() async {
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
      await Process.run('npm', ['config', 'set', 'proxy', httpProxy],
          runInShell: true);
      await Process.run('npm', ['config', 'set', 'https-proxy', httpProxy],
          runInShell: true);
    } catch (_) {}
  }

  static Future<void> _clearNpmProxy() async {
    try {
      await Process.run('npm', ['config', 'delete', 'proxy'], runInShell: true);
      await Process.run('npm', ['config', 'delete', 'https-proxy'],
          runInShell: true);
    } catch (_) {}
  }
}
