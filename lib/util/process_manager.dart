import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/core/checksum.dart';
import 'package:lux/util/utils.dart';

import '../error.dart';
import 'elevate.dart';

// Cache elevation status — check once, reuse forever.
bool? _elevatedCache;

/// Returns true if the current process has administrator privileges.
/// Uses a cached result — only checks once per app session.
Future<bool> _isElevated() async {
  if (_elevatedCache != null) return _elevatedCache!;
  try {
    // Use PowerShell but with a very short timeout — if it fails, assume not elevated.
    final r = await Process.run('powershell.exe', [
      '-noprofile', '-NonInteractive', '-command',
      '([Security.Principal.WindowsPrincipal]'
          '[Security.Principal.WindowsIdentity]::GetCurrent())'
          '.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
    ]).timeout(const Duration(seconds: 5));
    _elevatedCache = r.stdout.toString().trim().toLowerCase() == 'true';
  } catch (_) {
    _elevatedCache = false;
  }
  return _elevatedCache!;
}

class ProcessManager {
  Process? process;

  final String path;
  final List<String> args;
  final bool needElevate;

  ProcessManager(this.path, this.args, this.needElevate);

  Future<void> run() async {
    if (Platform.isWindows) {
      await verifyCoreBinary(path);

      if (needElevate) {
        if (await _isElevated()) {
          // lux.exe was started elevated (via LuxApp scheduled task).
          // Kill any orphan lux_core from previous sessions first.
          try {
            final existing = await Process.run(
                'taskkill', ['/F', '/IM', 'lux_core.exe', '/T'],
                runInShell: false);
            if (existing.exitCode == 0) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          } catch (_) {}
          // Start lux_core directly — inherits elevation, no UAC needed.
          process = await Process.start(path, args, runInShell: false);
          process?.stdout.transform(utf8.decoder).forEach(debugPrint);
          process?.stderr.transform(utf8.decoder).forEach(debugPrint);
          // Give lux_core time to bind its port (TUN/wintun init takes longer)
          await Future.delayed(const Duration(seconds: 2));
        } else {
          // Not elevated — use Start-Process -Verb RunAs (shows UAC).
          // This happens when the LuxApp task hasn't been registered yet
          // (i.e. manual install without running the installer).
          process = await Process.start('powershell.exe', [
            '-noprofile',
            "Start-Process '$path' -Verb RunAs -windowstyle hidden "
                "-ArgumentList \"${args.join(' ')}\"",
          ], runInShell: false);
        }
      } else {
        // System proxy mode — no elevation needed, start directly.
        process = await Process.start('powershell.exe', [
          '-noprofile',
          "Start-Process '$path' -windowstyle hidden "
              "-ArgumentList \"${args.join(' ')}\"",
        ], runInShell: false);
      }
    } else {
      if (!kDebugMode) {
        DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        MacOsDeviceInfo macOsInfo = await deviceInfo.macOsInfo;
        final isBiggerThanMacOs15 = macOsInfo.majorVersion > 15;
        var owner = await getFileOwner(path);
        if (owner != "root" || isBiggerThanMacOs15) {
          if (!isBiggerThanMacOs15) {
            await verifyCoreBinary(path);
          }
          var i10nLabel = await getInitI10nLabel();
          var code = await elevate(path, i10nLabel.macOSElevateServiceInfo);
          if (code != 0) {
            throw CoreRunError("fail to elevate core, code: $code");
          }
        }
      }
      process = await Process.start(path, args);
      process?.stdout.transform(utf8.decoder).forEach(debugPrint);
      process?.stderr.transform(utf8.decoder).forEach(debugPrint);
    }
  }

  void exit() {
    process?.kill();
  }

  void watchExit() {
    // watch process kill
    // ref https://github.com/dart-lang/sdk/issues/12170
    if (Platform.isMacOS) {
      // windows not support https://github.com/dart-lang/sdk/issues/28603
      // for macos 任务管理器退出进程
      ProcessSignal.sigterm.watch().listen((_) {
        stdout.writeln('exit: sigterm');
        exit();
      });
    }
    // for macos, windows ctrl+c
    ProcessSignal.sigint.watch().listen((_) {
      stdout.writeln('exit: sigint');
      exit();
    });
  }
}
