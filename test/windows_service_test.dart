import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/error.dart';
import 'package:lux/util/process_manager.dart';
import 'package:lux/util/windows_service.dart';

import 'test_env.dart';

String _decodeEncodedCommand(String encoded) {
  final bytes = base64Decode(encoded);
  final units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

class _FakeLuxServiceServer {
  late final HttpServer _server;
  String token = 'svc-control-token-abcdef123456';
  String coreSha256;
  bool running = false;
  int startCoreCalls = 0;
  int stopCoreCalls = 0;
  Map<String, dynamic>? lastStartBody;

  _FakeLuxServiceServer(this.coreSha256);

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> writeMeta(String metaPath) async {
    final f = File(metaPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({
      'port': port,
      'token': token,
      'coreSha256': coreSha256,
      'version': '1.50.123',
      'pid': 4242,
    }));
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'GET' && path == '/health') {
      _json(req, 200, {
        'ok': true,
        'coreSha256': coreSha256,
        'version': '1.50.123',
        'running': running,
        'corePort': running ? 8000 : 0,
        'corePid': running ? 9999 : 0,
      });
      return;
    }

    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth != 'Bearer $token') {
      _json(req, 401, {'error': 'unauthorized'});
      return;
    }

    if (req.method == 'POST' && path == '/start-core') {
      final raw = await utf8.decoder.bind(req).join();
      lastStartBody = jsonDecode(raw) as Map<String, dynamic>;
      startCoreCalls++;
      running = true;
      _json(req, 200, {'ok': true, 'pid': 9999, 'port': lastStartBody!['port']});
      return;
    }

    if (req.method == 'POST' && path == '/stop-core') {
      stopCoreCalls++;
      running = false;
      _json(req, 200, {'ok': true});
      return;
    }

    _json(req, 404, {'error': 'not found'});
  }

  void _json(HttpRequest req, int status, Map<String, dynamic> data) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HttpOverrides? prevOverrides;

  setUpAll(() {
    installTestEnv();
    prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    HttpOverrides.global = prevOverrides;
  });

  group('WindowsServiceClient helpers', () {
    test('parseWhoamiCsvSid parses standard and localized whoami output', () {
      expect(
        WindowsServiceClient.parseWhoamiCsvSid(
            '"CORP\\daniel.silva","S-1-5-21-3623811015-3361044348-30300820-1013"\r\n'),
        'S-1-5-21-3623811015-3361044348-30300820-1013',
      );
      expect(WindowsServiceClient.parseWhoamiCsvSid('invalid'), '');
    });

    test('parseCoreArgs extracts homeDir, port, and secret cleanly', () {
      final parsed = ProcessManager.parseCoreArgs([
        '-home_dir="C:\\Users\\João Silva\\AppData\\Roaming\\com.github.igoogolx\\lux\\1.0"',
        '-port=8000',
        '-secret=5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
      ]);
      expect(parsed, isNotNull);
      expect(parsed!.homeDir,
          r'C:\Users\João Silva\AppData\Roaming\com.github.igoogolx\lux\1.0');
      expect(parsed.port, 8000);
      expect(parsed.secret, '5eec8115-2b2d-49cd-ac34-9b3119fe8d4e');

      // Missing secret returns null
      expect(ProcessManager.parseCoreArgs(['-port=8000']), isNull);
    });

    test('buildInstallInnerScript uses protected dir, locale-independent SIDs, and New-Service',
        () {
      final inner = WindowsServiceClient.buildInstallInnerScript(
        r"C:\Users\O'Brien\AppData\Local\Programs\lux\data\flutter_assets\assets\bin\lux_core.exe",
      );
      expect(inner, contains(r'C:\Program Files\LuxService'));
      expect(inner, contains('lux_service.exe'));
      expect(inner, contains('lux_core.exe'));
      expect(inner, contains('*S-1-5-18:(OI)(CI)F'));
      expect(inner, contains('*S-1-5-32-544:(OI)(CI)F'));
      expect(inner, contains('*S-1-5-32-545:(OI)(CI)RX'));
      expect(inner, contains('New-Service'));
      expect(inner, contains('Start-Service'));
      expect(inner, contains("O''Brien"));

      final outerArgs = WindowsServiceClient.buildElevatedInstallPowerShellArgs(
        r'C:\Lux\lux_core.exe',
      );
      final encodedIdx = outerArgs.indexOf('-EncodedCommand') + 1;
      final outer = _decodeEncodedCommand(outerArgs[encodedIdx]);
      expect(outer, contains('-Verb RunAs'));
      expect(outer, contains('-Wait -PassThru'));
      expect(outer, contains('NativeErrorCode -eq 1223'));
    });
  });

  group('ProcessManager + LuxCoreService integration', () {
    late Directory tempDir;
    late File bundledCore;
    late String bundledSha;
    late String metaPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lux_svc_test_');
      bundledCore = File('${tempDir.path}/lux_core.exe');
      await bundledCore.writeAsBytes(utf8.encode('lux-core-v1.50.123-binary'));
      bundledSha = sha256.convert(await bundledCore.readAsBytes()).toString();
      metaPath = '${tempDir.path}/service.json';
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('zero-UAC fast path when LuxCoreService is installed and up to date',
        () async {
      final svcServer = _FakeLuxServiceServer(bundledSha);
      await svcServer.start();
      addTearDown(svcServer.close);
      await svcServer.writeMeta(metaPath);

      final psCalls = <String>[];
      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(
              0, 0, '"CORP\\daniel.silva","S-1-5-21-100-200-300-1001"\r\n', '');
        }
        psCalls.add(exe);
        return ProcessResult(0, 0, '', '');
      }

      final client = WindowsServiceClient(
        metaPath: metaPath,
        runProcess: fakeRun,
      );
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\daniel.silva\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=8000',
          '-secret=5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: client,
      );

      await pm.run();

      // ZERO PowerShell / UAC calls!
      expect(psCalls, isEmpty);
      expect(svcServer.startCoreCalls, 1);
      expect(svcServer.lastStartBody, {
        'homeDir':
            r'C:\Users\daniel.silva\AppData\Roaming\com.github.igoogolx\lux\1.0',
        'port': 8000,
        'secret': '5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
        'userSid': 'S-1-5-21-100-200-300-1001',
      });
    });

    test(
        'first-time run prompts ONE UAC to install LuxCoreService, then subsequent runs use zero UAC',
        () async {
      final svcServer = _FakeLuxServiceServer(bundledSha);
      await svcServer.start();
      addTearDown(svcServer.close);

      int uacPrompts = 0;
      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"HOST\\user","S-1-5-21-1-2-3-1000"', '');
        }
        if (exe == 'powershell.exe') {
          uacPrompts++;
          // Simulate elevated installer starting LuxCoreService and writing service.json
          await svcServer.writeMeta(metaPath);
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final client = WindowsServiceClient(
        metaPath: metaPath,
        runProcess: fakeRun,
      );
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=8000',
          '-secret=5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: client,
      );

      // 1st run: installs service via 1 UAC prompt and starts core through service
      await pm.run();
      expect(uacPrompts, 1);
      expect(svcServer.startCoreCalls, 1);

      // 2nd run (reboot / restart): ZERO UAC prompts!
      await pm.run();
      expect(uacPrompts, 1, reason: 'Must NOT prompt UAC on subsequent launches');
      expect(svcServer.startCoreCalls, 2);
    });

    test('outdated LuxCoreService binary triggers one UAC update then starts core',
        () async {
      final svcServer = _FakeLuxServiceServer('0' * 64); // stale hash
      await svcServer.start();
      addTearDown(svcServer.close);
      await svcServer.writeMeta(metaPath);

      int uacUpdates = 0;
      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"HOST\\user","S-1-5-21-1-2-3-1000"', '');
        }
        if (exe == 'powershell.exe') {
          uacUpdates++;
          svcServer.coreSha256 = bundledSha;
          await svcServer.writeMeta(metaPath);
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final client = WindowsServiceClient(
        metaPath: metaPath,
        runProcess: fakeRun,
      );
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=8000',
          '-secret=5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: client,
      );

      await pm.run();
      expect(uacUpdates, 1);
      expect(svcServer.startCoreCalls, 1);
    });

    test('cancelling UAC during service install rethrows CoreElevationCancelledError without second UAC',
        () async {
      int psCalls = 0;
      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"HOST\\user","S-1-5-21-1-2-3-1000"', '');
        }
        if (exe == 'powershell.exe') {
          psCalls++;
          return ProcessResult(1, 1223, '', 'canceled');
        }
        return ProcessResult(0, 0, '', '');
      }

      final client = WindowsServiceClient(
        metaPath: metaPath,
        runProcess: fakeRun,
      );
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=8000',
          '-secret=5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: client,
      );

      await expectLater(pm.run(), throwsA(isA<CoreElevationCancelledError>()));
      expect(psCalls, 1, reason: 'Must NOT trigger a second fallback UAC prompt');
    });

    test('falls back to direct RunAs (with -user_sid) if service install fails for non-cancel reason',
        () async {
      final decodedScripts = <String>[];
      int psCall = 0;
      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"HOST\\user","S-1-5-21-9-8-7-1001"', '');
        }
        if (exe == 'powershell.exe') {
          psCall++;
          final idx = args.indexOf('-EncodedCommand') + 1;
          decodedScripts.add(_decodeEncodedCommand(args[idx]));
          if (psCall == 1) {
            // Simulate service install failing due to GPO restriction
            return ProcessResult(1, 5, '', 'Access denied creating service');
          }
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final client = WindowsServiceClient(
        metaPath: metaPath,
        runProcess: fakeRun,
      );
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=8000',
          '-secret=5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: client,
      );

      await pm.run();
      expect(psCall, 2);
      expect(decodedScripts[1], contains('-Verb RunAs'));
      expect(decodedScripts[1], contains('-user_sid=S-1-5-21-9-8-7-1001'));
    });

    test('non-elevated run stops service-managed worker before launching non-elevated',
        () async {
      final svcServer = _FakeLuxServiceServer(bundledSha)..running = true;
      await svcServer.start();
      addTearDown(svcServer.close);
      await svcServer.writeMeta(metaPath);

      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        return ProcessResult(0, 0, '', '');
      }

      final client = WindowsServiceClient(
        metaPath: metaPath,
        runProcess: fakeRun,
      );
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=8000',
          '-secret=5eec8115-2b2d-49cd-ac34-9b3119fe8d4e',
        ],
        false,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: client,
      );

      await pm.run();
      expect(svcServer.stopCoreCalls, 1);
      expect(svcServer.running, isFalse);
    });
  });
}
