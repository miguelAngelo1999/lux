import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/core/checksum.dart';
import 'package:lux/util/app_log.dart';
import 'package:lux/util/telemetry.dart' as telem;
import 'package:lux/util/utils.dart';

import '../error.dart';
import 'elevate.dart';

typedef ProcessRunFn = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  bool runInShell,
});

/// Windows ERROR_CANCELLED (user clicked No / Cancel on UAC prompt).
const int windowsErrorCancelledExitCode = 1223;

class ProcessManager {
  Process? process;

  String path;
  List<String> args;
  bool needElevate;

  final ProcessRunFn _runProcess;
  final bool _isWindows;

  ProcessManager(
    this.path,
    this.args,
    this.needElevate, {
    ProcessRunFn? runProcess,
    bool? isWindowsOverride,
  })  : _runProcess = runProcess ?? _defaultRunProcess,
        _isWindows = isWindowsOverride ?? Platform.isWindows;

  static Future<ProcessResult> _defaultRunProcess(
    String executable,
    List<String> arguments, {
    bool runInShell = false,
  }) {
    return Process.run(executable, arguments, runInShell: runInShell);
  }

  static String _psSingleQuote(String value) =>
      "'${value.replaceAll("'", "''")}'";

  /// Encodes a PowerShell script as UTF-16LE base64 for `-EncodedCommand`,
  /// avoiding Win32 quote/backslash/codepage mangling.
  @visibleForTesting
  static String encodePowerShellCommand(String script) {
    final units = script.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (int i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xFF;
      bytes[i * 2 + 1] = (units[i] >> 8) & 0xFF;
    }
    return base64Encode(bytes);
  }

  /// Builds the PowerShell script that launches [path] with [args] on Windows.
  ///
  /// When [needElevate] is true, `Start-Process -Verb RunAs` (without `-Wait`)
  /// blocks PowerShell ONLY until the user approves or cancels the UAC dialog
  /// and Windows spawns `lux_core.exe` — then exits immediately. Waiting for
  /// this exit code ensures UAC credential entry time never consumes the core
  /// `/ping` timeout, and UAC cancellation is detected immediately via exit
  /// code [windowsErrorCancelledExitCode] (1223).
  @visibleForTesting
  static String buildWindowsLaunchScript(
    String path,
    List<String> args, {
    required bool needElevate,
  }) {
    final escapedPath = _psSingleQuote(path);
    // Normalize any legacy PowerShell backtick-escaped quotes (`") to plain "
    // since the entire -ArgumentList value is single-quoted verbatim.
    final normalizedArgs =
        args.map((a) => a.replaceAll('`"', '"')).join(' ');
    final escapedArgs = _psSingleQuote(normalizedArgs);
    final verbFlag = needElevate ? '-Verb RunAs ' : '';

    return r"$ProgressPreference = 'SilentlyContinue'; "
        'try { '
        'Start-Process -FilePath $escapedPath '
        '-ArgumentList $escapedArgs '
        '$verbFlag'
        '-WindowStyle Hidden '
        '-ErrorAction Stop '
        '} catch { '
        r'$ex = $_.Exception; '
        r'while ($ex -ne $null) { '
        'if (\$ex -is [System.ComponentModel.Win32Exception] -and \$ex.NativeErrorCode -eq $windowsErrorCancelledExitCode) { exit $windowsErrorCancelledExitCode } '
        r'$ex = $ex.InnerException '
        r'}; '
        'if (\$_.Exception.Message -match "cancel") { exit $windowsErrorCancelledExitCode }; '
        r'[Console]::Error.WriteLine($_.Exception.Message); '
        r'exit 1 '
        '}';
  }

  @visibleForTesting
  static List<String> buildWindowsPowerShellArgs(
    String path,
    List<String> args, {
    required bool needElevate,
  }) {
    final script =
        buildWindowsLaunchScript(path, args, needElevate: needElevate);
    return [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encodePowerShellCommand(script),
    ];
  }

  Future<void> run() async {
    if (_isWindows) {
      // Best-effort cleanup of any orphaned non-elevated lux_core.exe before
      // spawning a new session. (Elevated cores are stopped gracefully via
      // POST /manager/exit by CoreManager before calling run().)
      try {
        await _runProcess('taskkill', ['/F', '/IM', 'lux_core.exe'],
            runInShell: false);
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {}

      // Checksum check is skipped on Windows — the Inno Setup installer already
      // verifies file integrity before installation.
      final processArgs =
          buildWindowsPowerShellArgs(path, args, needElevate: needElevate);

      appLog('CORE', 'launching lux_core.exe on Windows (needElevate=$needElevate)');
      final result = await _runProcess(
        'powershell.exe',
        processArgs,
        runInShell: false,
      );

      if (result.exitCode == 0) {
        appLog('CORE', 'lux_core.exe launched (needElevate=$needElevate)');
        return;
      }

      final stderrText = (result.stderr?.toString() ?? '').trim();
      if (needElevate && result.exitCode == windowsErrorCancelledExitCode) {
        appLog('CORE', 'Windows UAC elevation was cancelled by user');
        throw CoreElevationCancelledError();
      }

      appLog('CORE',
          'failed to launch lux_core.exe (exit=${result.exitCode}, needElevate=$needElevate): $stderrText');
      throw CoreRunError(
        stderrText.isNotEmpty
            ? 'Failed to start lux_core: $stderrText'
            : 'Failed to start lux_core (exit code ${result.exitCode})',
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
      try {
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
    if (Platform.isWindows) {
      try {
        Process.runSync('taskkill', ['/F', '/IM', 'lux_core.exe']);
      } catch (_) {}
    }
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
