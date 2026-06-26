import 'dart:io';

import 'package:flutter/foundation.dart';

/// Resets all network settings that lux_core may have set:
/// - System proxy (networksetup on macOS, registry on Windows)
/// - launchctl env vars (macOS) / user env vars (Windows)
/// - TUN interface removal (if stuck)
///
/// Call this when lux_core dies unexpectedly or when the user requests a manual reset.
class NetworkReset {
  /// Clears system proxy and env vars. Safe to call even if nothing was set.
  static Future<void> reset() async {
    if (Platform.isMacOS) {
      await _resetMacOS();
    } else if (Platform.isWindows) {
      await _resetWindows();
    }
  }

  static Future<void> _resetWindows() async {
    try {
      await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        // Disable manual proxy
        r'$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings";'
        r'Set-ItemProperty $k -Name ProxyEnable -Value 0 -Force;'
        // Restore AutoDetect
        r'Set-ItemProperty $k -Name AutoDetect -Value 1 -Force;'
        // Clear HTTP_PROXY env vars (user scope)
        r'[Environment]::SetEnvironmentVariable("HTTP_PROXY",$null,"User");'
        r'[Environment]::SetEnvironmentVariable("HTTPS_PROXY",$null,"User");'
        r'[Environment]::SetEnvironmentVariable("NO_PROXY",$null,"User");',
      ]);
      // Clear git proxy
      await Process.run('git', ['config', '--global', '--unset', 'http.proxy'], runInShell: true);
      await Process.run('git', ['config', '--global', '--unset', 'https.proxy'], runInShell: true);
    } catch (e) {
      debugPrint('[NetworkReset] Windows reset error: $e');
    }
    debugPrint('[NetworkReset] Windows reset complete');
  }

  static Future<void> _resetMacOS() async {
    final script = File('/tmp/lux_network_reset.sh');
    await script.writeAsString(
      '#!/bin/bash\n'
      '# Clear system proxy on all interfaces\n'
      'while IFS= read -r SVC; do\n'
      '  [[ -z "\$SVC" || "\$SVC" == *"An asterisk"* ]] && continue\n'
      '  networksetup -setwebproxystate "\$SVC" off 2>/dev/null || true\n'
      '  networksetup -setsecurewebproxystate "\$SVC" off 2>/dev/null || true\n'
      'done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)\n'
      '\n'
      '# Clear launchctl env vars\n'
      'for VAR in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy; do\n'
      '  launchctl unsetenv "\$VAR" 2>/dev/null || true\n'
      'done\n'
      '\n'
      '# Remove LUX_PROXY lines from /etc/zshenv\n'
      'grep -v "LUX_PROXY" /etc/zshenv > /tmp/lux_zshenv_clean 2>/dev/null || true\n'
      'cp /tmp/lux_zshenv_clean /etc/zshenv 2>/dev/null || true\n'
      '\n'
      '# Clear git proxy\n'
      'git config --global --unset http.proxy 2>/dev/null || true\n'
      'git config --global --unset https.proxy 2>/dev/null || true\n'
      '\n'
      'echo "NETWORK_RESET_OK"\n',
    );

    await Process.run('chmod', ['+x', script.path]);
    // Try sudo -n first (no prompt if sudoers configured)
    final result = await Process.run('sudo', ['-n', 'bash', script.path]);
    if (result.exitCode != 0) {
      // Fall back to osascript
      await Process.run('/usr/bin/osascript', ['-e',
        "do shell script \"bash '${script.path}'\" "
        "with prompt \"Lux needs admin to reset network settings\" "
        "with administrator privileges"]);
    }
    await script.delete().catchError((_) => script);
    debugPrint('[NetworkReset] reset complete');
  }
}
