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
/// Name of the high-priority logon task for lux.exe itself.
const _appTaskName = 'LuxApp';

/// Checks whether the LuxCore scheduled task is registered.
Future<bool> _isTaskRegistered() async {
  final r = await Process.run('schtasks', ['/query', '/tn', _taskName],
      runInShell: false);
  return r.exitCode == 0;
}

/// Path to the args file that lux_core reads on task launch.
String _argsFilePath() =>
    '${Platform.environment['TEMP'] ?? 'C:\\Windows\\Temp'}\\lux_core_args.txt';

/// Creates the LuxCore scheduled task (requires one UAC prompt on first run).
/// On-demand only — triggered by lux.exe via schtasks /run, not at logon.
/// The task reads session args (port/secret) from a temp file written by lux.exe.
Future<bool> _registerElevatedTask() async {
  final launcherPath = '${Platform.environment['LOCALAPPDATA']}\\Programs\\lux\\lux_core_launcher.ps1';
  final launcherScript = r'''
$argsFile = "$env:TEMP\lux_core_args.txt"
if (Test-Path $argsFile) {
  $parts = Get-Content $argsFile
  $exe   = $parts[0]
  $args  = $parts[1..($parts.Length-1)]
  Start-Process $exe -WindowStyle Hidden -ArgumentList $args
}
''';
  await File(launcherPath).writeAsString(launcherScript);

  final psScript = '''
\$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$launcherPath"'
\$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew
\$principal = New-ScheduledTaskPrincipal -UserId (whoami) -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskName "$_taskName" -Action \$action -Settings \$settings -Principal \$principal -Force | Out-Null

# Also register a high-priority logon task for lux.exe itself so it starts
# before other startup apps and internet is up early in the session.
\$luxExe = "${'${Platform.environment['LOCALAPPDATA']}\\Programs\\lux\\lux.exe'}"
\$appAction   = New-ScheduledTaskAction -Execute \$luxExe
\$appTrigger  = New-ScheduledTaskTrigger -AtLogOn -User (whoami)
\$appSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew
\$appPrincipal = New-ScheduledTaskPrincipal -UserId (whoami) -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskName "$_appTaskName" -Action \$appAction -Trigger \$appTrigger -Settings \$appSettings -Principal \$appPrincipal -Force | Out-Null

Write-Output "OK"
''';

  final ts = DateTime.now().millisecondsSinceEpoch;
  final scriptFile = 'C:\\Windows\\Temp\\lux_register_task_$ts.ps1';
  await File(scriptFile).writeAsString(psScript);

  try {
    // Write a sentinel file that the elevated script will create on success
    final sentinelFile = 'C:\\Windows\\Temp\\lux_task_ok_$ts.txt';
    // Append sentinel write to the script
    await File(scriptFile).writeAsString(
      (await File(scriptFile).readAsString()) +
      '\nSet-Content "$sentinelFile" "OK"\n',
    );

    await Process.run('powershell.exe', [
      '-noprofile', '-NonInteractive', '-command',
      '\$p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru '
          '-WindowStyle Hidden '
          '-ArgumentList @("-ExecutionPolicy","Bypass","-File","$scriptFile"); '
          'if (\$p) { \$p.ExitCode } else { 1 }',
    ]);

    // Check sentinel file — more reliable than stdout capture across UAC
    final ok = await File(sentinelFile).exists();
    await File(sentinelFile).delete().catchError((_) => File(sentinelFile));
    return ok;
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

/// Try to launch lux_core via the scheduled task if it's registered.
/// Returns true if the task was triggered, false if task doesn't exist yet.
Future<bool> _tryLaunchViaTask(String corePath, List<String> args) async {
  if (!await _isTaskRegistered()) return false;
  await _writeArgsFile(corePath, args);
  await _runViaScheduledTask();
  await Future.delayed(const Duration(seconds: 2));
  return true;
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
        // Try task-based silent elevation first; fall back to classic RunAs.
        final launched = await _tryLaunchViaTask(path, args);
        if (!launched) {
          // Classic UAC prompt — works always.
          // Use -ArgumentList as array to avoid quoting issues with spaces in paths.
          final argList = args.map((a) => "'$a'").join(',');
          process = await Process.start('powershell.exe', [
            '-noprofile',
            "Start-Process '$path' -Verb RunAs -WindowStyle Hidden -ArgumentList @($argList)",
          ], runInShell: false);
          // Register the task in the background so next launch is silent.
          _registerElevatedTask().then((ok) {
            debugPrint('Task registration: $ok');
          });
        }
      } else {
        final argList = args.map((a) => "'$a'").join(',');
        process = await Process.start('powershell.exe', [
          '-noprofile',
          "Start-Process '$path' -WindowStyle Hidden -ArgumentList @($argList)",
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
