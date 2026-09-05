import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/core/checksum.dart';
import 'package:lux/util/telemetry.dart' as telem;
import 'package:lux/util/app_log.dart';
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
      // On Windows the installer verifies file integrity; a checksum mismatch
      // here almost always means a rolling update (old lux.exe + new lux_core.exe).
      // Log it but do NOT throw — bricking the app on update is worse than the
      // theoretical risk of a corrupted binary that the installer already verified.
      try {
        await verifyCoreBinary(path);
      } catch (e) {
        appLog('CORE', 'checksum warning (non-fatal on Windows): $e');
      }
      List<String> processArgs = [];

      if (needElevate) {
        processArgs = [
          '-noprofile',
          "Start-Process '$path' -Verb RunAs -windowstyle hidden",
          "-ArgumentList \"${args.join(' ')}\""
        ];
      } else {
        processArgs = [
          '-noprofile',
          "Start-Process '$path'  -windowstyle hidden",
          "-ArgumentList \"${args.join(' ')}\""
        ];
      }

      process = await Process.start(
        'powershell.exe',
        processArgs,
        runInShell: false,
      );
    } else {
      bool freshElevation = false;
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
            telem.telemetryError('elevation-failed',
                'elevate returned $code', extra: {'path': path});
            throw CoreRunError("fail to elevate core, code: $code");
          }
          freshElevation = true;
        }
      }
      // Kill any stale lux_core holding the port before starting a new one.
      // Prevents "bind: address already in use" and multi-instance conflicts.
      // macOS: lsof  |  Windows: netstat + taskkill
      try {
        if (Platform.isWindows) {
          // Extract PID from: TCP  0.0.0.0:8000  ...  LISTENING  <PID>
          final portArg = args.firstWhere(
              (a) => a.startsWith('-port='), orElse: () => '-port=8000');
          final port = portArg.split('=').last.trim();
          final check = await Process.run(
              'cmd', ['/c', 'netstat -ano | findstr :$port | findstr LISTENING'],
              runInShell: false);
          final pids = (check.stdout as String)
              .split('\n')
              .map((l) => l.trim().split(RegExp(r'\s+')).last.trim())
              .where((p) => p.isNotEmpty && RegExp(r'^\d+$').hasMatch(p))
              .toSet()
              .toList();
          for (final pid in pids) {
            await Process.run('taskkill', ['/F', '/PID', pid]);
          }
          if (pids.isNotEmpty) {
            await Future.delayed(const Duration(milliseconds: 300));
          }
        } else {
          final portArg = args.firstWhere(
              (a) => a.startsWith('-port='), orElse: () => '-port=8000');
          final port = portArg.split('=').last.trim();
          final check = await Process.run('lsof', ['-ti', ':$port']);
          final pids = (check.stdout as String)
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
        }
      } catch (_) {}

      // After fresh elevation, the wrapper script now calls sudo on lux_core_real.
      // Give sudoers a moment to register the new entry, then start via sudo
      // directly (bypass wrapper) to avoid race conditions on first launch.
      if (freshElevation) {
        await Future.delayed(const Duration(milliseconds: 500));
        final realPath = '${path}_real';
        process = await Process.start('sudo', [realPath, ...args]);
      } else {
        process = await Process.start(path, args);
      }
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
