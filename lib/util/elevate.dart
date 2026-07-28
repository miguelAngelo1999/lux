import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:lux/util/app_log.dart';

var sudoCommandPath = "/usr/bin/osascript";

Future<String?> getFileOwner(String path) async {
  var result = await Process.run("ls", ["-l", path]);

  var output = result.stdout.toString().trim();

  if (output.isEmpty) {
    return null;
  } else {
    output = output.split("\n").last;

    var parts =
        output.split(" ").where((element) => element.isNotEmpty).toList();

    return parts[2];
  }
}

/// Checks if the NOPASSWD sudoers entry already exists for lux_core
/// AND covers the proxy/cert scripts (so sudo -n works without prompting).
Future<bool> _isSudoersConfigured(String corePath) async {
  final sudoersFile = File('/etc/sudoers.d/lux_core');
  if (!await sudoersFile.exists()) return false;
  // Always check the canonical installed path — not the build/derived path.
  // Using the derived path fails when running from a dev build or after an update.
  const canonicalReal = '/Applications/Lux.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core_real';
  try {
    final result = await Process.run('sudo', ['-n', '-l', canonicalReal],
        runInShell: false).timeout(const Duration(seconds: 3));
    return result.exitCode == 0;
  } catch (_) {
    return true;
  }
}

/// Checks if the core binary is already wrapped with the sudo script.
Future<bool> _isWrapped(String corePath) async {
  final realPath = '${corePath}_real';
  final realFile = File(realPath);
  return await realFile.exists();
}

Future<int> elevate(String path, message) async {
  // Fast path: check if NOPASSWD sudoers is configured AND wrapper exists.
  appLog('CORE', 'elevate() checking wrapper and sudoers...');
  if (await _isWrapped(path) && await _isSudoersConfigured(path)) {
    appLog('CORE', 'elevate() fast path — already configured');
    debugPrint('Elevation already configured via sudoers, skipping prompt.');
    return 0;
  }
  appLog('CORE', 'elevate() running osascript setup prompt');

  // First time: set up the wrapper + sudoers entry (requires one-time admin prompt)
  final dir = File(path).parent.path;
  final realPath = '$dir/lux_core_real';
  final user = Platform.environment['USER'] ?? 'root';
  // Always use the canonical /Applications path for sudoers — never the build path.
  // The build path changes on every build; the installed path is stable.
  const canonicalReal = '/Applications/Lux.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core_real';

  // Write the setup script to a temp file to avoid quoting hell in osascript
  final scriptFile = File('/tmp/lux_elevate_setup.sh');
  final scriptContent = '''#!/bin/bash
set -e
BIN="$path"
REAL="$realPath"
USER_NAME="$user"

if [ ! -f "\$REAL" ]; then
  mv "\$BIN" "\$REAL"
fi

# Write wrapper with hardcoded path to the real binary
printf '#!/bin/bash\\nexec sudo "$realPath" "\$@"\\n' > "\$BIN"
chmod 755 "\$BIN"
chown root:wheel "\$REAL"
chmod 770 "\$REAL"
mkdir -p /Library/PrivilegedHelperTools/com.github.igoogolx.lux
chown "\$USER_NAME":staff /Library/PrivilegedHelperTools/com.github.igoogolx.lux
chmod 755 /Library/PrivilegedHelperTools/com.github.igoogolx.lux
echo "\$USER_NAME ALL=(root) NOPASSWD: $canonicalReal *" > /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_proxy_apply.sh *" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_proxy_clear.sh" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_cert_install.sh" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_network_reset.sh" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_updater.sh" >> /etc/sudoers.d/lux_core
chmod 0440 /etc/sudoers.d/lux_core

# Enable Touch ID for sudo — use sudo_local (persists across macOS updates)
# /etc/pam.d/sudo is reset on OS updates; sudo_local is preserved
SUDO_LOCAL=/etc/pam.d/sudo_local
if [ ! -f "\$SUDO_LOCAL" ] || ! grep -qE '^auth[[:space:]]+sufficient[[:space:]]+pam_tid\\.so' "\$SUDO_LOCAL" 2>/dev/null; then
  cat > "\$SUDO_LOCAL" << 'PAM'
# sudo_local: local config file which survives system update and is included for sudo
auth       sufficient     pam_tid.so
PAM
fi
# Also patch /etc/pam.d/sudo to include sudo_local if not already there
PAM_SUDO=/etc/pam.d/sudo
if ! grep -q "sudo_local" "\$PAM_SUDO" 2>/dev/null; then
  sed -i '' '1a\\
auth       include        sudo_local' "\$PAM_SUDO" 2>/dev/null || true
fi
''';
  await scriptFile.writeAsString(scriptContent);
  await Process.run('chmod', ['+x', scriptFile.path]);

  // Run the script with admin privileges via osascript
  final escapedScript =
      'do shell script "bash /tmp/lux_elevate_setup.sh" with prompt "$message" with administrator privileges';

  var process = await Process.start(sudoCommandPath, ["-e", escapedScript]);

  process.stdout.transform(utf8.decoder).forEach(debugPrint);
  process.stderr.transform(utf8.decoder).forEach(debugPrint);
  final code = await process.exitCode;

  // Clean up temp script
  try { await scriptFile.delete(); } catch (_) {}

  return code;
}
