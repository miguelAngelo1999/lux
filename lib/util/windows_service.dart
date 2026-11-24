import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/error.dart';
import 'package:lux/util/app_log.dart';

/// Native Windows Service (`LuxCoreService`) client and one-time installer.
///
/// Architecture:
/// - First time Mixed/TUN mode is used on Windows, one UAC prompt copies the
///   bundled `lux_core.exe` into an admin-only directory
///   (`C:\Program Files\LuxService\`) and registers `LuxCoreService`
///   (`LocalSystem`, Automatic start).
/// - On every subsequent Lux launch, reboot, or `System -> Mixed/TUN` switch,
///   Lux reads `C:\ProgramData\LuxService\service.json` and calls the service's
///   authenticated loopback control API (`POST /start-core`) with ZERO UAC
///   prompts — even for non-admin corporate users.
/// - If a Lux update ships a newer `lux_core.exe` whose SHA-256 differs from
///   the installed service binary (and the installer wasn't already elevated),
///   one UAC prompt updates the service binary cleanly.
const String windowsServiceName = 'LuxCoreService';
const String windowsServiceDir = r'C:\Program Files\LuxService';
const String windowsServiceMetaDir = r'C:\ProgramData\LuxService';
const String windowsServiceMetaPath = r'C:\ProgramData\LuxService\service.json';
const int _windowsErrorCancelledExitCode = 1223;

typedef ServiceProcessRunFn = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  bool runInShell,
});

class WindowsServiceHealth {
  final int port;
  final String token;
  final bool ok;
  final String coreSha256;
  final String version;
  final bool running;
  final int corePort;
  final int corePid;

  const WindowsServiceHealth({
    required this.port,
    required this.token,
    required this.ok,
    required this.coreSha256,
    required this.version,
    required this.running,
    required this.corePort,
    required this.corePid,
  });
}

class WindowsServiceClient {
  final String metaPath;
  final ServiceProcessRunFn _runProcess;
  final Dio _dio;

  String? _cachedUserSid;
  String? _cachedBinaryKey;
  String? _cachedBinarySha256;

  WindowsServiceClient({
    this.metaPath = windowsServiceMetaPath,
    ServiceProcessRunFn? runProcess,
    Dio? dio,
  })  : _runProcess = runProcess ?? _defaultRunProcess,
        _dio = dio ?? _createDirectDio();

  static Future<ProcessResult> _defaultRunProcess(
    String executable,
    List<String> arguments, {
    bool runInShell = false,
  }) {
    return Process.run(executable, arguments, runInShell: runInShell);
  }

  static Dio _createDirectDio() {
    final d = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 10),
    ));
    d.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'DIRECT';
        return client;
      },
    );
    return d;
  }

  static String _psSingleQuote(String value) =>
      "'${value.replaceAll("'", "''")}'";

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

  /// Parses the SID (`S-1-5-...`) from `whoami /user /fo csv /nh` output.
  @visibleForTesting
  static String parseWhoamiCsvSid(String output) {
    final match = RegExp(r'S-1-5-[0-9-]+').firstMatch(output);
    return match?.group(0) ?? '';
  }

  /// Returns the current logged-in Windows user's SID (e.g. `S-1-5-21-...`),
  /// cached for the lifetime of the app. Used by `lux_core.exe -user_sid=...`
  /// when running under `LocalSystem` so WinINET proxy settings target this
  /// user's registry hive instead of `.DEFAULT`.
  Future<String> getCurrentUserSid() async {
    if (_cachedUserSid != null) return _cachedUserSid!;
    try {
      final res = await _runProcess(
        'whoami.exe',
        ['/user', '/fo', 'csv', '/nh'],
        runInShell: false,
      );
      if (res.exitCode == 0) {
        final sid = parseWhoamiCsvSid(res.stdout?.toString() ?? '');
        if (sid.isNotEmpty) {
          _cachedUserSid = sid;
          return sid;
        }
      }
    } catch (e) {
      appLog('SERVICE', 'failed to read current user SID: $e');
    }
    return '';
  }

  /// Computes and caches the lowercase SHA-256 hex digest of [filePath].
  Future<String?> computeFileSha256(String filePath) async {
    try {
      final f = File(filePath);
      if (!await f.exists()) return null;
      final stat = await f.stat();
      final key = '$filePath|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
      if (_cachedBinaryKey == key && _cachedBinarySha256 != null) {
        return _cachedBinarySha256;
      }
      final digest = await sha256.bind(f.openRead()).first;
      final hex = digest.toString().toLowerCase();
      _cachedBinaryKey = key;
      _cachedBinarySha256 = hex;
      return hex;
    } catch (e) {
      appLog('SERVICE', 'failed to hash $filePath: $e');
      return null;
    }
  }

  Future<({int port, String token, String coreSha256})?> _readMeta() async {
    try {
      final f = File(metaPath);
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      final port = raw['port'];
      final token = raw['token'];
      final sha = raw['coreSha256'];
      if (port is! int || port < 1024 || port > 65535) return null;
      if (token is! String || token.isEmpty) return null;
      return (
        port: port,
        token: token,
        coreSha256: sha is String ? sha.toLowerCase() : '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Checks whether `LuxCoreService` is installed, running, and answering
  /// `/health` on its control port. Returns `null` if unavailable.
  Future<WindowsServiceHealth?> checkHealth() async {
    final meta = await _readMeta();
    if (meta == null) return null;
    try {
      final res = await _dio.get(
        'http://127.0.0.1:${meta.port}/health',
        options: Options(
          sendTimeout: const Duration(milliseconds: 1500),
          receiveTimeout: const Duration(milliseconds: 1500),
        ),
      );
      if (res.statusCode == 200 && res.data is Map) {
        final data = res.data as Map;
        if (data['ok'] == true) {
          return WindowsServiceHealth(
            port: meta.port,
            token: meta.token,
            ok: true,
            coreSha256:
                (data['coreSha256'] as String? ?? meta.coreSha256).toLowerCase(),
            version: data['version'] as String? ?? '',
            running: data['running'] == true,
            corePort: data['corePort'] as int? ?? 0,
            corePid: data['corePid'] as int? ?? 0,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// Returns the live [WindowsServiceHealth] if the service is running AND its
  /// installed `lux_core.exe` matches [bundledCorePath]'s SHA-256.
  Future<WindowsServiceHealth?> getReadyUpToDateService(
    String bundledCorePath,
  ) async {
    final health = await checkHealth();
    if (health == null || !health.ok) return null;
    final expectedSha = await computeFileSha256(bundledCorePath);
    if (expectedSha == null || expectedSha.isEmpty) return null;
    if (health.coreSha256 != expectedSha) {
      appLog('SERVICE',
          'LuxCoreService binary outdated (installed=${health.coreSha256.substring(0, health.coreSha256.length.clamp(0, 12))}, bundled=${expectedSha.substring(0, 12)})');
      return null;
    }
    return health;
  }

  /// Builds the elevated PowerShell script that installs or updates
  /// `LuxCoreService` in `C:\Program Files\LuxService` with strict admin-only
  /// NTFS ACLs (using locale-independent well-known SIDs).
  @visibleForTesting
  static String buildInstallInnerScript(String bundledCorePath) {
    final srcCore = _psSingleQuote(bundledCorePath);
    final svcDir = _psSingleQuote(windowsServiceDir);
    final metaDir = _psSingleQuote(windowsServiceMetaDir);

    return r"$ErrorActionPreference = 'Stop'; "
        r"$ProgressPreference = 'SilentlyContinue'; "
        "\$svcName = '$windowsServiceName'; "
        "\$svcDir = $svcDir; "
        "\$metaDir = $metaDir; "
        "\$srcCore = $srcCore; "
        r"$dstSvc = Join-Path $svcDir 'lux_service.exe'; "
        r"$dstCore = Join-Path $svcDir 'lux_core.exe'; "
        r"$existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue; "
        r"if ($null -ne $existing -and $existing.Status -ne 'Stopped') { "
        r"  try { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue } catch {}; "
        r"  for ($i = 0; $i -lt 30; $i++) { "
        r"    $existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue; "
        r"    if ($null -eq $existing -or $existing.Status -eq 'Stopped') { break }; "
        r"    Start-Sleep -Milliseconds 200 "
        r"  } "
        r"}; "
        r"Get-Process lux_core,lux_service -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; "
        r"Start-Sleep -Milliseconds 300; "
        r"New-Item -ItemType Directory -Path $svcDir -Force | Out-Null; "
        r"New-Item -ItemType Directory -Path $metaDir -Force | Out-Null; "
        r"& icacls.exe $svcDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' /grant:r '*S-1-5-32-544:(OI)(CI)F' /grant:r '*S-1-5-32-545:(OI)(CI)RX' | Out-Null; "
        r"& icacls.exe $metaDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' /grant:r '*S-1-5-32-544:(OI)(CI)F' /grant:r '*S-1-5-32-545:(OI)(CI)RX' | Out-Null; "
        r"foreach ($dst in @($dstSvc, $dstCore)) { "
        r"  if (Test-Path $dst) { "
        r"    try { Remove-Item -Path $dst -Force } catch { "
        r"      $old = $dst + '.old'; "
        r"      Remove-Item -Path $old -Force -ErrorAction SilentlyContinue; "
        r"      Move-Item -Path $dst -Destination $old -Force -ErrorAction SilentlyContinue "
        r"    } "
        r"  }; "
        r"  Copy-Item -Path $srcCore -Destination $dst -Force "
        r"}; "
        r'$binPath = "`"$dstSvc`" -service"; '
        r"$existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue; "
        r"if ($null -eq $existing) { "
        r"  New-Service -Name $svcName -BinaryPathName $binPath -DisplayName 'Lux Core Service' -StartupType Automatic -Description 'Provides privileged network tunnel management for Lux proxy' | Out-Null "
        r"} else { "
        r"  Set-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $svcName) -Name ImagePath -Value $binPath; "
        r"  Set-Service -Name $svcName -StartupType Automatic -DisplayName 'Lux Core Service' "
        r"}; "
        r"& sc.exe failure $svcName reset= 86400 actions= restart/3000/restart/5000/restart/10000 2>$null | Out-Null; "
        r"Start-Service -Name $svcName";
  }

  /// Builds the outer PowerShell args that invoke the elevated service
  /// installer via `-Verb RunAs -Wait -PassThru`, detecting UAC cancellation
  /// via locale-independent `Win32Exception.NativeErrorCode == 1223`.
  @visibleForTesting
  static List<String> buildElevatedInstallPowerShellArgs(
    String bundledCorePath,
  ) {
    final innerEncoded =
        encodePowerShellCommand(buildInstallInnerScript(bundledCorePath));
    final outerScript = r"$ProgressPreference = 'SilentlyContinue'; "
        'try { '
        "\$p = Start-Process -FilePath 'powershell.exe' "
        "-ArgumentList '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $innerEncoded' "
        '-Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop; '
        r'exit $p.ExitCode '
        '} catch { '
        r'$ex = $_.Exception; '
        r'while ($ex -ne $null) { '
        'if (\$ex -is [System.ComponentModel.Win32Exception] -and \$ex.NativeErrorCode -eq $_windowsErrorCancelledExitCode) { exit $_windowsErrorCancelledExitCode } '
        r'$ex = $ex.InnerException '
        r'}; '
        'if (\$_.Exception.Message -match "cancel") { exit $_windowsErrorCancelledExitCode }; '
        r'[Console]::Error.WriteLine($_.Exception.Message); '
        r'exit 1 '
        '}';
    return [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encodePowerShellCommand(outerScript),
    ];
  }

  /// Prompts ONE UAC elevation to install/update and start `LuxCoreService`,
  /// then waits up to [readyTimeout] for `/health` to come online.
  ///
  /// Throws [CoreElevationCancelledError] immediately if the user cancels UAC.
  Future<WindowsServiceHealth> installOrUpdateService(
    String bundledCorePath, {
    Duration readyTimeout = const Duration(seconds: 10),
  }) async {
    appLog('SERVICE', 'installing/updating LuxCoreService via one-time UAC');
    final args = buildElevatedInstallPowerShellArgs(bundledCorePath);
    final res = await _runProcess('powershell.exe', args, runInShell: false);

    if (res.exitCode == _windowsErrorCancelledExitCode) {
      appLog('SERVICE', 'LuxCoreService UAC prompt was cancelled by user');
      throw CoreElevationCancelledError();
    }

    if (res.exitCode != 0) {
      final stderrText = (res.stderr?.toString() ?? '').trim();
      appLog('SERVICE',
          'LuxCoreService install failed (exit=${res.exitCode}): $stderrText');
      throw CoreRunError(
        stderrText.isNotEmpty
            ? 'Failed to install LuxCoreService: $stderrText'
            : 'Failed to install LuxCoreService (exit code ${res.exitCode})',
      );
    }

    final deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final health = await checkHealth();
      if (health != null && health.ok) {
        appLog('SERVICE',
            'LuxCoreService online on 127.0.0.1:${health.port} (sha=${health.coreSha256.substring(0, health.coreSha256.length.clamp(0, 12))})');
        return health;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    throw CoreRunError('LuxCoreService did not become healthy in time');
  }

  /// Asks `LuxCoreService` to spawn the elevated `lux_core.exe` worker on
  /// [port] with [homeDir], [secret], and [userSid] — ZERO UAC prompt.
  Future<void> startCore({
    required WindowsServiceHealth health,
    required String homeDir,
    required int port,
    required String secret,
    String userSid = '',
  }) async {
    final res = await _dio.post(
      'http://127.0.0.1:${health.port}/start-core',
      data: {
        'homeDir': homeDir,
        'port': port,
        'secret': secret,
        'userSid': userSid,
      },
      options: Options(
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer ${health.token}',
        },
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 12),
      ),
    );
    if (res.statusCode != 200) {
      throw CoreRunError('LuxCoreService /start-core returned ${res.statusCode}');
    }
    appLog('SERVICE',
        'LuxCoreService started elevated lux_core.exe on port=$port (pid=${res.data is Map ? res.data['pid'] : '?'})');
  }

  /// Best-effort stop of any elevated worker supervised by `LuxCoreService`.
  /// Works even from a non-elevated Lux process.
  Future<bool> stopCore() async {
    final health = await checkHealth();
    if (health == null || !health.ok) return false;
    try {
      await _dio.post(
        'http://127.0.0.1:${health.port}/stop-core',
        options: Options(
          headers: {
            HttpHeaders.authorizationHeader: 'Bearer ${health.token}',
          },
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      appLog('SERVICE', 'LuxCoreService stopped managed lux_core.exe');
      return true;
    } catch (e) {
      appLog('SERVICE', 'LuxCoreService /stop-core error: $e');
      return false;
    }
  }
}
