import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/error.dart';
import 'package:lux/home.dart';
import 'package:lux/model/app.dart';
import 'package:lux/util/process_manager.dart';

import 'test_env.dart';

/// Decodes a UTF-16LE base64 PowerShell `-EncodedCommand` payload back into
/// plain text for assertions.
String _decodePowerShellEncodedCommand(String encoded) {
  final bytes = base64Decode(encoded);
  final units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

/// Lightweight fake `lux_core` HTTP server simulating Windows admin/non-admin
/// privilege checks (`GET /is-admin`, `POST /manager/start` returning 403 when
/// non-elevated in mixed/tun mode, `POST /manager/exit`, `/ping`, `/setting`).
class _FakeCoreServer {
  late final HttpServer _server;
  String mode = 'system';
  bool isAdmin = false;
  bool isStarted = false;
  bool alive = true;
  bool force403Once = false;
  int pingStatusCode = 200;

  final List<String> log = [];

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  String get baseUrl => '127.0.0.1:${_server.port}';

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method;

    if (!alive) {
      final sock = await req.response.detachSocket(writeHeaders: false);
      sock.destroy();
      return;
    }

    if (path == '/ping') {
      req.response.statusCode = pingStatusCode;
      req.response.write(pingStatusCode == 200 ? '.' : 'not ready');
      await req.response.close();
      return;
    }

    log.add('$method $path (admin=$isAdmin, mode=$mode)');

    if (method == 'GET' && path == '/is-admin') {
      _json(req, 200, {'isAdmin': isAdmin});
      return;
    }

    if (method == 'GET' && path == '/manager') {
      _json(req, 200, {'isStarted': isStarted});
      return;
    }

    if (method == 'GET' && path == '/setting') {
      _json(req, 200, {
        'setting': {
          'mode': mode,
          'autoLaunch': false,
          'autoConnect': false,
          'defaultInterface': '',
          'localServer': {'port': 1090, 'allowLan': false},
          'bypassCidrs': <String>[],
          'dns': {'fakeIp': true, 'disableCache': false},
          'hijackDns': {'enabled': true},
          'autoMode': {'enabled': false, 'type': 'url', 'url': ''},
        }
      });
      return;
    }

    if (method == 'PUT' && path == '/setting') {
      final body = await utf8.decoder.bind(req).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['mode'] is String) {
        mode = data['mode'] as String;
      }
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    if (method == 'POST' && path == '/manager/start') {
      if (force403Once) {
        force403Once = false;
        _json(req, 403, {
          'message':
              'administrator privileges are required to start in non-system proxy mode',
          'code': coreHttpErrorNotElevatedCode,
        });
        return;
      }
      if (mode != 'system' && !isAdmin) {
        _json(req, 403, {
          'message':
              'administrator privileges are required to start in non-system proxy mode',
          'code': coreHttpErrorNotElevatedCode,
        });
        return;
      }
      isStarted = true;
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    if (method == 'POST' && path == '/manager/stop') {
      isStarted = false;
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    if (method == 'POST' && path == '/manager/exit') {
      isStarted = false;
      alive = false;
      // Simulate os.Exit(0) dropping connection without response
      final sock = await req.response.detachSocket(writeHeaders: false);
      sock.destroy();
      return;
    }

    if (method == 'GET' && path == '/proxies') {
      _json(req, 200, {'proxies': <dynamic>[], 'selectedId': ''});
      return;
    }

    req.response.statusCode = 404;
    await req.response.close();
  }

  void _json(HttpRequest req, int status, Map<String, dynamic> payload) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(payload));
    req.response.close();
  }
}

class _WatchdogTestCore extends CoreManager {
  _WatchdogTestCore({
    required AppStateModel appState,
    required Stream<List<ConnectivityResult>> connectivityStream,
  }) : super(
          '127.0.0.1:1',
          null,
          'tok',
          _noop,
          appState: appState,
          connectivityStream: connectivityStream,
          checkConnectivity: () async => [ConnectivityResult.wifi],
          isWindowsOverride: true,
        );

  static void _noop() {}

  bool fakeRestarting = false;
  int startCalls = 0;
  Object? startError;

  @override
  bool get isRestartingCore => fakeRestarting;

  @override
  Future<bool> getIsStarted() async => false;

  @override
  Future<void> start() async {
    startCalls++;
    if (startError != null) throw startError!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HttpOverrides? previousHttpOverrides;

  setUpAll(() {
    installTestEnv();
    previousHttpOverrides = HttpOverrides.current;
    // Allow loopback HttpClient connections to the local fake lux_core server.
    HttpOverrides.global = null;
  });

  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  group('ProcessManager Windows UAC launcher', () {
    test('builds UTF-16LE EncodedCommand with RunAs and 1223 cancel detection',
        () {
      final psArgs = ProcessManager.buildWindowsPowerShellArgs(
        r"C:\Program Files\Lux\assets\bin\lux_core.exe",
        [
          '-home_dir=`"C:\\Users\\José O\'Brien\\AppData\\Roaming\\lux\\1.0`"',
          '-port=8000',
          '-secret=abc',
        ],
        needElevate: true,
      );

      expect(psArgs, contains('-NoProfile'));
      expect(psArgs, contains('-NonInteractive'));
      expect(psArgs, contains('-EncodedCommand'));

      final encodedIdx = psArgs.indexOf('-EncodedCommand') + 1;
      final decoded = _decodePowerShellEncodedCommand(psArgs[encodedIdx]);

      expect(decoded, contains('-Verb RunAs'));
      expect(decoded, contains('-WindowStyle Hidden'));
      expect(decoded, contains('-ErrorAction Stop'));
      // Single quote in username doubled for PowerShell single-quoted string,
      // and legacy backtick-quotes normalized to plain double quotes.
      expect(
        decoded,
        contains(
            r'''-ArgumentList '-home_dir="C:\Users\José O''Brien\AppData\Roaming\lux\1.0" -port=8000 -secret=abc' '''),
      );
      expect(decoded, contains('NativeErrorCode -eq 1223'));
      expect(decoded, contains('exit 1223'));
    });

    test('omits -Verb RunAs when needElevate is false', () {
      final script = ProcessManager.buildWindowsLaunchScript(
        r'C:\Lux\lux_core.exe',
        ['-home_dir="C:\\Lux"', '-port=8000'],
        needElevate: false,
      );
      expect(script, isNot(contains('-Verb RunAs')));
      expect(script, contains('-WindowStyle Hidden'));
    });

    test('awaits PowerShell exit (UAC dialog) and detects cancel (1223)',
        () async {
      final uacCompleter = Completer<ProcessResult>();
      final calls = <String>[];

      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        true,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          calls.add(exe);
          if (exe == 'taskkill') {
            return ProcessResult(0, 0, '', '');
          }
          return uacCompleter.future;
        },
      );

      bool completed = false;
      final runFuture = pm.run().whenComplete(() => completed = true);

      // Give microtasks time to invoke powershell.exe
      await Future.delayed(const Duration(milliseconds: 250));
      expect(calls, contains('powershell.exe'));
      expect(completed, isFalse,
          reason: 'run() must wait while Windows UAC dialog is open');

      // User clicks Cancel on UAC -> exit code 1223
      uacCompleter.complete(ProcessResult(1, 1223, '', 'canceled by user'));

      await expectLater(runFuture, throwsA(isA<CoreElevationCancelledError>()));
    });

    test('throws CoreRunError with stderr on non-cancel launch failure',
        () async {
      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        true,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          if (exe == 'taskkill') return ProcessResult(0, 0, '', '');
          return ProcessResult(1, 1, '', 'file not found');
        },
      );

      await expectLater(
        pm.run(),
        throwsA(isA<CoreRunError>()
            .having((e) => e.message, 'message', contains('file not found'))),
      );
    });
  });

  group('CoreManager Windows live elevation & UAC ping timing', () {
    late _FakeCoreServer server;
    late StreamController<List<ConnectivityResult>> connectivityController;
    late AppStateModel appState;

    setUp(() async {
      server = _FakeCoreServer();
      await server.start();
      connectivityController =
          StreamController<List<ConnectivityResult>>.broadcast();
      appState = AppStateModel(ThemeMode.light, const Locale('en'));
    });

    tearDown(() async {
      await server.close();
      await connectivityController.close();
    });

    CoreManager makeCore(
      ProcessManager pm, {
      VoidCallback? onReady,
      Duration pingTimeout = const Duration(seconds: 5),
      Future<bool> Function()? readServiceDeclinedFn,
      Future<void> Function(bool)? writeServiceDeclinedFn,
    }) {
      return CoreManager(
        server.baseUrl,
        pm,
        'secret-token',
        onReady ?? () {},
        appState: appState,
        connectivityStream: connectivityController.stream,
        checkConnectivity: () async => [ConnectivityResult.wifi],
        pingTimeout: pingTimeout,
        pingRetryDelay: const Duration(milliseconds: 25),
        isWindowsOverride: true,
        readProxyModeFn: () async => server.mode == 'system'
            ? ProxyMode.system
            : server.mode == 'tun'
                ? ProxyMode.tun
                : ProxyMode.mixed,
        readServiceDeclinedFn: readServiceDeclinedFn ?? () async => false,
        writeServiceDeclinedFn: writeServiceDeclinedFn ?? (_) async {},
      );
    }

    test(
        'Bug #1 fix: switching system -> mixed while running elevates core before /manager/start (no 403)',
        () async {
      server.mode = 'system';
      server.isAdmin = false;
      server.isStarted = true;

      final launchElevatedFlags = <bool>[];
      int readyCount = 0;

      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        false,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          if (exe == 'taskkill') return ProcessResult(0, 0, '', '');
          final encodedIdx = args.indexOf('-EncodedCommand') + 1;
          final script = _decodePowerShellEncodedCommand(args[encodedIdx]);
          final elevated = script.contains('-Verb RunAs');
          launchElevatedFlags.add(elevated);
          // Simulated new core boots with the requested privilege level
          server.isAdmin = elevated;
          server.alive = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      final core = makeCore(pm, onReady: () => readyCount++);
      addTearDown(core.dispose);

      await core.saveSetting(Setting(mode: ProxyMode.mixed));

      expect(launchElevatedFlags, [true],
          reason: 'Should relaunch lux_core.exe elevated once');
      expect(server.isAdmin, isTrue);
      expect(server.mode, 'mixed');
      expect(server.isStarted, isTrue);
      expect(readyCount, 1);

      // Verify clean ordering: stop old system mode -> exit old core -> start elevated
      final stopIdx = server.log
          .indexWhere((e) => e.startsWith('POST /manager/stop'));
      final exitIdx = server.log
          .indexWhere((e) => e.startsWith('POST /manager/exit'));
      final startIdx = server.log.indexWhere(
          (e) => e.startsWith('POST /manager/start (admin=true, mode=mixed)'));
      expect(stopIdx, greaterThanOrEqualTo(0));
      expect(exitIdx, greaterThan(stopIdx));
      expect(startIdx, greaterThan(exitIdx));
    });

    test(
        'Bug #2 fix: slow UAC credential entry exceeding pingTimeout does NOT cause fail to ping core',
        () async {
      server.mode = 'mixed';
      server.alive = false;

      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        true,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          if (exe == 'taskkill') return ProcessResult(0, 0, '', '');
          // Simulate user taking longer than pingTimeout (350ms > 150ms)
          // to type admin username & password into the Windows UAC prompt.
          await Future.delayed(const Duration(milliseconds: 350));
          server.isAdmin = true;
          server.alive = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      int readyCount = 0;
      final core = makeCore(
        pm,
        onReady: () => readyCount++,
        pingTimeout: const Duration(milliseconds: 150),
      );
      addTearDown(core.dispose);

      // Must succeed because pingTimeout starts AFTER UAC approves!
      await core.run();
      expect(readyCount, 1);
      expect(server.isAdmin, isTrue);
    });

    test(
        'cancelling UAC during system -> mixed respawns non-elevated core, reverts to system, and reconnects',
        () async {
      server.mode = 'system';
      server.isAdmin = false;
      server.isStarted = true;

      final launchElevatedFlags = <bool>[];

      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        false,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          if (exe == 'taskkill') return ProcessResult(0, 0, '', '');
          final encodedIdx = args.indexOf('-EncodedCommand') + 1;
          final script = _decodePowerShellEncodedCommand(args[encodedIdx]);
          final elevated = script.contains('-Verb RunAs');
          launchElevatedFlags.add(elevated);
          if (elevated) {
            return ProcessResult(1, 1223, '', 'canceled');
          }
          server.isAdmin = false;
          server.alive = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      final core = makeCore(pm);
      addTearDown(core.dispose);

      await expectLater(
        core.saveSetting(Setting(mode: ProxyMode.mixed)),
        throwsA(isA<CoreElevationCancelledError>()),
      );

      // Tried elevated (cancelled), then recovered non-elevated
      expect(launchElevatedFlags, [true, false]);
      expect(pm.needElevate, isFalse);
      expect(server.alive, isTrue);
      expect(server.mode, 'system');
      expect(server.isStarted, isTrue);
    });

    test('start() elevates live when switching mode while disconnected',
        () async {
      server.mode = 'mixed';
      server.isAdmin = false;
      server.isStarted = false;

      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        false,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          if (exe == 'taskkill') return ProcessResult(0, 0, '', '');
          final encodedIdx = args.indexOf('-EncodedCommand') + 1;
          final script = _decodePowerShellEncodedCommand(args[encodedIdx]);
          server.isAdmin = script.contains('-Verb RunAs');
          server.alive = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      final core = makeCore(pm);
      addTearDown(core.dispose);

      await core.start();
      expect(server.isAdmin, isTrue);
      expect(server.isStarted, isTrue);
    });

    test('start() recovers on unexpected 403 NotElevated via one-shot elevation',
        () async {
      server.mode = 'mixed';
      // Pretend isAdmin initially reported true, but /manager/start still returned 403 once
      server.isAdmin = true;
      server.force403Once = true;

      int elevatedLaunches = 0;
      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        false,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          if (exe == 'taskkill') return ProcessResult(0, 0, '', '');
          elevatedLaunches++;
          server.isAdmin = true;
          server.alive = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      final core = makeCore(pm);
      addTearDown(core.dispose);

      await core.start();
      expect(elevatedLaunches, 1);
      expect(server.isStarted, isTrue);
    });

    test('switching mixed -> system keeps elevated LuxCoreService core running without downgrading',
        () async {
      server.mode = 'mixed';
      server.isAdmin = true;
      server.isStarted = true;

      final launchCalls = <String>[];
      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        true,
        isWindowsOverride: true,
        runProcess: (exe, args, {bool runInShell = false}) async {
          launchCalls.add(exe);
          return ProcessResult(0, 0, '', '');
        },
      );

      final core = makeCore(pm);
      addTearDown(core.dispose);

      await core.saveSetting(Setting(mode: ProxyMode.system));
      expect(launchCalls, isEmpty,
          reason:
              'Must keep elevated core running in System mode so UWP loopback works with zero UAC');
      expect(pm.needElevate, isTrue);
      expect(server.isAdmin, isTrue);
      expect(server.mode, 'system');
      expect(server.isStarted, isTrue);
      expect(appState.windowsLimitedMode, isFalse);
    });

    test('makeRequestUntilSuccess times out cleanly on non-200 without recursing',
        () async {
      server.pingStatusCode = 503;

      final pm = ProcessManager(
        r'C:\Lux\lux_core.exe',
        ['-port=8000'],
        false,
        isWindowsOverride: true,
      );
      final core = makeCore(
        pm,
        pingTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(core.dispose);

      await expectLater(
        core.ping(),
        throwsA(isA<CoreRunError>()
            .having((e) => e.message, 'message', contains('timeout'))),
      );
    });
  });

  group('WatchdogController elevation guards', () {
    test('skips tick while core restart/elevation is in progress', () async {
      final connectivity = StreamController<List<ConnectivityResult>>.broadcast();
      final appState = AppStateModel(ThemeMode.light, const Locale('en'))
        ..userWantsRunning = true;
      final core = _WatchdogTestCore(
        appState: appState,
        connectivityStream: connectivity.stream,
      )..fakeRestarting = true;
      addTearDown(() async {
        core.dispose();
        await connectivity.close();
      });

      final wd = WatchdogController(
        checkConnectivity: () async => [ConnectivityResult.wifi],
        retryDelayBase: const Duration(milliseconds: 5),
      );

      await wd.tick(core, appState);
      expect(core.startCalls, 0);
      expect(appState.userWantsRunning, isTrue);
    });

    test('stops retrying immediately on CoreElevationCancelledError and 403',
        () async {
      final connectivity = StreamController<List<ConnectivityResult>>.broadcast();
      final appState = AppStateModel(ThemeMode.light, const Locale('en'))
        ..userWantsRunning = true;
      final core = _WatchdogTestCore(
        appState: appState,
        connectivityStream: connectivity.stream,
      )..startError = CoreElevationCancelledError();
      addTearDown(() async {
        core.dispose();
        await connectivity.close();
      });

      final notes = <String>[];
      final wd = WatchdogController(
        checkConnectivity: () async => [ConnectivityResult.wifi],
        retryDelayBase: const Duration(milliseconds: 5),
        showNotification: notes.add,
      );

      await wd.tick(core, appState);
      expect(core.startCalls, 1,
          reason: 'Must not retry 3 times after UAC cancellation');
      expect(appState.userWantsRunning, isFalse);
      expect(notes, isNotEmpty);

      // Also verify 403 NotElevated stops retrying immediately
      appState.userWantsRunning = true;
      core.startCalls = 0;
      core.startError = DioException(
        requestOptions: RequestOptions(path: '/manager/start'),
        response: Response(
          requestOptions: RequestOptions(path: '/manager/start'),
          statusCode: 403,
          data: {'code': coreHttpErrorNotElevatedCode, 'message': 'not admin'},
        ),
        type: DioExceptionType.badResponse,
      );

      await wd.tick(core, appState);
      expect(core.startCalls, 1);
      expect(appState.userWantsRunning, isFalse);
    });
  });
}
