import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/core/checksum.dart';
import 'package:lux/util/utils.dart';

import '../error.dart';
import 'elevate.dart';

/// Name of the Windows Task Scheduler task used for silent elevation.
const _taskName = 'LuxCore';

/// Checks whether the LuxCore scheduled task is registered.
Future<bool> _isTaskRegistered() async {
  final r = await Process.run('schtasks', ['/query', '/tn', _taskName],
      runInShell: false);
  return r.exitCode == 0;
}

/// Path to the args file that lux_core reads on task launch.
String _argsFilePath() =>
    '${Platform.environment['TEMP'] ?? 'C:\\Windows\\Temp'}\\lux_core_args.txt';

/// Creates or updates the LuxCore scheduled task (requires one UAC prompt on first run).
/// The task runs a launcher that reads args from a temp file — so args can
/// change each session without needing to re-register the task.
Future<bool> _registerElevatedTask() async {
  final argsFile = _argsFilePath();
  // The task action: PowerShell reads args from file, then starts lux_core
  final launcherScript = r'''
$argsFile = "$env:TEMP\lux_core_args.txt"
if (Test-Path $argsFile) {
  $parts = Get-Content $argsFile
  $exe   = $parts[0]
  $args  = $parts[1..($parts.Length-1)]
  Start-Process $exe -WindowStyle Hidden -ArgumentList $args
}
''';
  final launcherPath = '${Platform.environment['LOCALAPPDATA']}\\Programs\\lux\\lux_core_launcher.ps1';
  await File(launcherPath).writeAsString(launcherScript);

  final psScript = '''
\$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$launcherPath"'
\$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -AllowStartIfOnBatteries \$true -DontStopIfGoingOnBatteries \$true
\$principal = New-ScheduledTaskPrincipal -UserId (whoami) -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskName "$_taskName" -Action \$action -Settings \$settings -Principal \$principal -Force | Out-Null
Write-Output "OK"
''';

  final ts = DateTime.now().millisecondsSinceEpoch;
  final scriptFile = 'C:\\Windows\\Temp\\lux_register_task_$ts.ps1';
  await File(scriptFile).writeAsString(psScript);

  try {
    final result = await Process.run('powershell.exe', [
      '-noprofile', '-NonInteractive', '-command',
      '\$p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru '
          '-WindowStyle Hidden '
          '-ArgumentList @("-ExecutionPolicy","Bypass","-File","$scriptFile"); '
          'if (\$p) { \$p.ExitCode } else { 1 }',
    ]);
    return result.exitCode == 0 &&
        (int.tryParse(result.stdout.toString().trim()) ?? 1) == 0;
  } finally {
    await File(scriptFile).delete().catchError((_) => File(scriptFile));
  }
}

/// Writes the session args to the args file (no elevation needed).
Future<void> _writeArgsFile(String corePath, List<String> args) async {
  final lines = [corePath, ...args].join('\n');
  await File(_argsFilePath()).writeAsString(lines);
}

/// Starts the already-registered LuxCore task silently (no UAC).
/// Returns the launched Process handle by finding lux_core.exe by path.
Future<void> _runViaScheduledTask() async {
  await Process.run('schtasks', ['/run', '/tn', _taskName], runInShell: false);
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
        // Check if task is already registered
        final taskExists = await _isTaskRegistered();
        if (!taskExists) {
          // One-time setup: register with UAC prompt (only needed once per install)
          final ok = await _registerElevatedTask();
          if (!ok) {
            // Fall back to classic RunAs if task registration failed
            process = await Process.start('powershell.exe', [
              '-noprofile',
              "Start-Process '$path' -Verb RunAs -windowstyle hidden -ArgumentList \"${args.join(' ')}\"",
            ], runInShell: false);
            return;
          }
        }
        // Write session-specific args (port + secret change each run)
        await _writeArgsFile(path, args);
        // Silent launch via scheduled task — no UAC prompt
        await _runViaScheduledTask();
        // Give the task launcher a moment to spawn lux_core
        await Future.delayed(const Duration(seconds: 2));
      } else {
        process = await Process.start('powershell.exe', [
          '-noprofile',
          "Start-Process '$path' -windowstyle hidden -ArgumentList \"${args.join(' ')}\"",
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
