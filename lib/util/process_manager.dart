import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/core/checksum.dart';
import 'package:lux/util/utils.dart';

import '../error.dart';
import 'elevate.dart';

class ProcessManager {
  Process? process;

  final String path;
  final List<String> args;
  final bool needElevate;

  ProcessManager(this.path, this.args, this.needElevate);

  Future<void> run() async {
    if (Platform.isWindows) {
      await verifyCoreBinary(path);

      // Kill any zombie lux_core holding port 1090 before starting a new one.
      // This prevents "bind: Only one usage of each socket address" errors.
      try {
        await Process.run('powershell.exe', [
          '-noprofile', '-NonInteractive', '-command',
          r'$pid = (Get-NetTCPConnection -LocalPort 1090 -EA SilentlyContinue | '
          r'Where-Object State -eq "Listen" | Select-Object -First 1).OwningProcess;'
          r'if ($pid) { Stop-Process -Id $pid -Force -EA SilentlyContinue }',
        ]);
        // Brief pause for OS to release the port
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (_) {}

      List<String> processArgs = [];

      if (needElevate) {
        processArgs = [
          '-noprofile',
          "Start-Process '$path' -Verb RunAs -windowstyle hidden -ArgumentList \"${args.join(' ')}\"",
        ];
      } else {
        processArgs = [
          '-noprofile',
          "Start-Process '$path' -windowstyle hidden -ArgumentList \"${args.join(' ')}\"",
        ];
      }

      process = await Process.start(
        'powershell.exe',
        processArgs,
        runInShell: false,
      );
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
      // Kill any stale lux_core holding port 1090 before starting a new one.
      // This prevents "bind: address already in use" on restart/crash.
      try {
        final portCheck = await Process.run('lsof', ['-ti', ':1090']);
        final pids = (portCheck.stdout as String)
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        for (final pid in pids) {
          await Process.run('kill', ['-9', pid]);
        }
        if (pids.isNotEmpty) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
      } catch (_) {}
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
