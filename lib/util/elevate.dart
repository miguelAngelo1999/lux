import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:lux/util/app_log.dart';

var sudoCommandPath = "/usr/bin/osascript";

/// Canonical installed location of the real core binary.
///
/// Always use this for the sudoers rule rather than the path derived at
/// runtime: the derived path changes between dev builds and after an update,
/// which silently invalidates the NOPASSWD entry.
const canonicalRealCorePath =
    '/Applications/Lux.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core_real';

const _helperDir = '/Library/PrivilegedHelperTools/com.github.igoogolx.lux';

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

/// Checks whether the NOPASSWD sudoers entry exists AND actually authorises
/// the real core binary.
///
/// The sudoers file is root-owned 0440 so we cannot read it. Instead we ask
/// sudo itself via `sudo -n -l <path>`, which succeeds only when a NOPASSWD
/// rule covers that exact path.
Future<bool> _isSudoersConfigured() async {
  final sudoersFile = File('/etc/sudoers.d/lux_core');
  if (!await sudoersFile.exists()) return false;
  try {
    final result = await Process.run(
      'sudo',
      ['-n', '-l', canonicalRealCorePath],
      runInShell: false,
    ).timeout(const Duration(seconds: 3));
    return result.exitCode == 0;
  } catch (_) {
    // Timed out or sudo unavailable — assume configured rather than
    // re-prompting on every launch.
    return true;
  }
}

/// Checks if the core binary has been split into wrapper + `_real`.
Future<bool> _isWrapped(String corePath) async {
  return File('${corePath}_real').exists();
}

/// Grants lux_core the privileges it needs to create a TUN interface and
/// configure the system proxy.
///
/// Rather than making the core binary setuid, we split it in two:
///
///   lux_core       plain 755 shell script -> `exec sudo lux_core_real "$@"`
///   lux_core_real  the actual binary, root:wheel 4755
///
/// A setuid binary runs with euid=0 but ruid=501. Routing through sudo yields
/// ruid=0 as well, which is what the privileged network configuration path
/// requires. Going through sudo also means macOS validates a real
/// authorisation rather than an unsigned setuid bit.
///
/// Mode 4755 (not 770) matters: `other` needs read+execute, because the
/// invoking user is typically in `staff`, not `wheel`. Dropping those bits is
/// what produces "Permission denied" at exec time.
Future<int> elevate(String path, message) async {
  appLog('CORE', 'elevate() checking wrapper and sudoers...');
  if (await _isWrapped(path) && await _isSudoersConfigured()) {
    appLog('CORE', 'elevate() fast path — already configured');
    debugPrint('Elevation already configured via sudoers, skipping prompt.');
    return 0;
  }
  appLog('CORE', 'elevate() running osascript setup prompt');

  final dir = File(path).parent.path;
  final realPath = '$dir/lux_core_real';
  final user = Platform.environment['USER'] ?? 'root';

  // Write the setup steps to a temp script. Doing this inline in osascript
  // means three levels of quoting; a file avoids that entirely.
  final scriptFile = File('/tmp/lux_elevate_setup.sh');
  final scriptContent = '''#!/bin/bash
set -e
BIN="$path"
REAL="$realPath"
USER_NAME="$user"

# Clear quarantine first. macOS blocks mv/chmod on downloaded apps until this
# is done, and it requires root — which we have inside this osascript block.
xattr -cr /Applications/Lux.app 2>/dev/null || true

# Split the binary out, once.
if [ ! -f "\$REAL" ]; then
  mv "\$BIN" "\$REAL"
fi

# Wrapper: a plain script, NOT setuid. The kernel ignores setuid on
# interpreted files, and stripping the read bit makes it unexecutable.
printf '#!/bin/bash\\nexec sudo "$realPath" "\$@"\\n' > "\$BIN"
chmod 755 "\$BIN"

chown root:wheel "\$REAL"
chmod 4755 "\$REAL"

mkdir -p $_helperDir
chown "\$USER_NAME":staff $_helperDir
chmod 755 $_helperDir

# NOPASSWD rules. The core uses the canonical installed path so the rule
# survives updates and dev builds.
echo "\$USER_NAME ALL=(root) NOPASSWD: $canonicalRealCorePath *" > /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash $_helperDir/lux_proxy_apply.sh *" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash $_helperDir/lux_proxy_clear.sh" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash $_helperDir/lux_cert_install.sh" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash $_helperDir/lux_network_reset.sh" >> /etc/sudoers.d/lux_core
echo "\$USER_NAME ALL=(root) NOPASSWD: /bin/bash $_helperDir/lux_updater.sh" >> /etc/sudoers.d/lux_core
chmod 0440 /etc/sudoers.d/lux_core

# Reject a malformed sudoers file rather than leaving it in place, which
# would break sudo entirely.
if ! visudo -c -f /etc/sudoers.d/lux_core >/dev/null 2>&1; then
  rm -f /etc/sudoers.d/lux_core
  echo "sudoers validation failed; entry removed" >&2
  exit 1
fi

# Touch ID for sudo. Write sudo_local, which survives OS updates, then
# include it from /etc/pam.d/sudo (that file IS reset by updates).
SUDO_LOCAL=/etc/pam.d/sudo_local
if [ ! -f "\$SUDO_LOCAL" ] || ! grep -qE '^auth[[:space:]]+sufficient[[:space:]]+pam_tid\\.so' "\$SUDO_LOCAL" 2>/dev/null; then
  cat > "\$SUDO_LOCAL" << 'PAM'
# sudo_local: local config which survives system updates and is included by sudo
auth       sufficient     pam_tid.so
PAM
fi
PAM_SUDO=/etc/pam.d/sudo
if ! grep -q "sudo_local" "\$PAM_SUDO" 2>/dev/null; then
  sed -i '' '1a\\
auth       include        sudo_local' "\$PAM_SUDO" 2>/dev/null || true
fi
''';

  await scriptFile.writeAsString(scriptContent);
  await Process.run('chmod', ['+x', scriptFile.path]);

  final escapedScript =
      'do shell script "bash /tmp/lux_elevate_setup.sh" with prompt "$message" with administrator privileges';

  var process = await Process.start(sudoCommandPath, ["-e", escapedScript]);

  process.stdout.transform(utf8.decoder).forEach(debugPrint);
  process.stderr.transform(utf8.decoder).forEach(debugPrint);
  final code = await process.exitCode;

  try {
    await scriptFile.delete();
  } catch (_) {}

  appLog('CORE', 'elevate() setup exited $code');
  return code;
}
