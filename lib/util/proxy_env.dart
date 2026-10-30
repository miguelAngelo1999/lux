import 'dart:io';

import 'package:lux/util/utils.dart';

/// Sets/clears the proxy environment variables that Node.js / Electron tools
/// (Antigravity, VS Code, Slack, npm, yarn, …) need in order to route through
/// lux and trust its proxy CA. These tools have their own network stack and
/// ignore the OS/WinINET system proxy, so they require HTTP_PROXY/HTTPS_PROXY
/// to be set explicitly, plus NODE_EXTRA_CA_CERTS for cert trust.
///
/// IMPORTANT: this must be invoked from EVERY path that starts/stops the core
/// (manual toggle, tray, auto-connect, watchdog restart, wake reconnect). That
/// is why it lives in CoreManager.start()/stop() and not in a single UI widget
/// — an earlier version only set these on the header toggle, so users who
/// auto-connected or used the tray never got them and Antigravity could not
/// connect.

const _proxyUrl = 'http://127.0.0.1:1090';
const _noProxy = 'localhost,127.0.0.1,::1,10.255.0.1,*.local';

const _envKeys = [
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'http_proxy',
  'https_proxy',
  'NO_PROXY',
  'no_proxy',
  'NODE_EXTRA_CA_CERTS',
];

/// Apply proxy env vars for the current platform. Safe to call repeatedly.
Future<void> applyProxyEnv() async {
  if (Platform.isMacOS) {
    await _applyMacOS();
  } else if (Platform.isWindows) {
    await _applyWindows();
  }
}

/// Clear the proxy env vars for the current platform.
Future<void> clearProxyEnv() async {
  if (Platform.isMacOS) {
    await _clearMacOS();
  } else if (Platform.isWindows) {
    await _clearWindows();
  }
}

Future<String?> _caBundlePath() async {
  final homeDir = await getHomeDir();
  final sep = Platform.isWindows ? '\\' : '/';
  final p = '$homeDir${sep}proxy_ca_bundle.pem';
  return await File(p).exists() ? p : null;
}

// ── macOS: launchctl setenv (GUI-session scope) ──────────────────────────────

Future<void> _applyMacOS() async {
  final ca = await _caBundlePath();
  final vars = <String, String>{
    'HTTP_PROXY': _proxyUrl,
    'HTTPS_PROXY': _proxyUrl,
    'http_proxy': _proxyUrl,
    'https_proxy': _proxyUrl,
    'NO_PROXY': _noProxy,
    'no_proxy': _noProxy,
    if (ca != null) 'NODE_EXTRA_CA_CERTS': ca,
    // Go helpers (Antigravity's language_server) may read SSL_CERT_FILE rather
    // than NODE_EXTRA_CA_CERTS. Same bundle (system roots + user-trusted CAs +
    // proxy CA). 2026-10-30: setting BOTH by hand and restarting Antigravity
    // fixed "x509: certificate signed by unknown authority"; which of the two
    // did it was not isolated.
    if (ca != null) 'SSL_CERT_FILE': ca,
  };
  for (final e in vars.entries) {
    await Process.run('launchctl', ['setenv', e.key, e.value]);
  }
}

Future<void> _clearMacOS() async {
  for (final k in [..._envKeys, 'SSL_CERT_FILE', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_OPTIONS']) {
    await Process.run('launchctl', ['unsetenv', k]);
  }
}

// ── Windows: persistent User-scope environment variables ─────────────────────

Future<void> _applyWindows() async {
  final ca = await _caBundlePath();
  final vars = <String, String>{
    'HTTP_PROXY': _proxyUrl,
    'HTTPS_PROXY': _proxyUrl,
    'http_proxy': _proxyUrl,
    'https_proxy': _proxyUrl,
    'NO_PROXY': _noProxy,
    'no_proxy': _noProxy,
    if (ca != null) 'NODE_EXTRA_CA_CERTS': ca,
  };
  for (final e in vars.entries) {
    await Process.run('powershell.exe', [
      '-noprofile', '-NonInteractive', '-WindowStyle', 'Hidden', '-command',
      '[Environment]::SetEnvironmentVariable("${e.key}","${e.value}","User")',
    ]);
  }
}

Future<void> _clearWindows() async {
  for (final k in [..._envKeys, 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_OPTIONS']) {
    await Process.run('powershell.exe', [
      '-noprofile', '-NonInteractive', '-WindowStyle', 'Hidden', '-command',
      '[Environment]::SetEnvironmentVariable("$k",\$null,"User")',
    ]);
  }
}
