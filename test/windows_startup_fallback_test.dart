import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/error.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/util/process_manager.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/windows_service.dart';
import 'package:lux/widget/windows_service_banner.dart';
import 'package:provider/provider.dart';

import 'test_env.dart';

class _FakeServiceAndCore {
  late final HttpServer _svcServer;
  late final HttpServer _coreServer;

  final String coreSha256;
  final String svcToken = 'svc-tok-12345';
  String mode = 'system';
  bool isAdmin = false;
  bool isStarted = false;
  bool coreAlive = false;
  int startCoreCalls = 0;
  int stopCoreCalls = 0;

  _FakeServiceAndCore(this.coreSha256);

  int get svcPort => _svcServer.port;
  int get corePort => _coreServer.port;
  String get coreBaseUrl => '127.0.0.1:$corePort';

  Future<void> start() async {
    _svcServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _svcServer.listen(_handleSvc);
    _coreServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _coreServer.listen(_handleCore);
  }

  Future<void> close() async {
    await _svcServer.close(force: true);
    await _coreServer.close(force: true);
  }

  Future<void> writeServiceMeta(String metaPath) async {
    final f = File(metaPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({
      'port': svcPort,
      'token': svcToken,
      'coreSha256': coreSha256,
      'version': '1.50.124',
      'pid': 4242,
    }));
  }

  Future<void> _handleSvc(HttpRequest req) async {
    if (req.method == 'GET' && req.uri.path == '/health') {
      _json(req, 200, {
        'ok': true,
        'coreSha256': coreSha256,
        'version': '1.50.124',
        'running': coreAlive && isAdmin,
        'corePort': corePort,
        'corePid': 9999,
      });
      return;
    }
    if (req.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $svcToken') {
      _json(req, 401, {'error': 'unauthorized'});
      return;
    }
    if (req.method == 'POST' && req.uri.path == '/start-core') {
      startCoreCalls++;
      coreAlive = true;
      isAdmin = true;
      _json(req, 200, {'ok': true, 'pid': 9999, 'port': corePort});
      return;
    }
    if (req.method == 'POST' && req.uri.path == '/stop-core') {
      stopCoreCalls++;
      if (isAdmin) {
        coreAlive = false;
        isStarted = false;
      }
      _json(req, 200, {'ok': true});
      return;
    }
    _json(req, 404, {'error': 'not found'});
  }

  Future<void> _handleCore(HttpRequest req) async {
    if (!coreAlive) {
      final s = await req.response.detachSocket(writeHeaders: false);
      s.destroy();
      return;
    }
    final path = req.uri.path;
    final method = req.method;
    if (path == '/ping') {
      req.response.statusCode = 200;
      req.response.write('.');
      await req.response.close();
      return;
    }
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
    if (method == 'GET' && path == '/setting/interfaces') {
      _json(req, 200, {'interfaces': <dynamic>[]});
      return;
    }
    if (method == 'PUT' && path == '/setting') {
      final body = await utf8.decoder.bind(req).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['mode'] is String) mode = data['mode'] as String;
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }
    if (method == 'POST' && path == '/manager/start') {
      if (mode != 'system' && !isAdmin) {
        _json(req, 403, {
          'message': 'administrator privileges required',
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
      coreAlive = false;
      final s = await req.response.detachSocket(writeHeaders: false);
      s.destroy();
      return;
    }
    if (method == 'GET' && path == '/proxies') {
      _json(req, 200, {'proxies': <dynamic>[], 'selectedId': ''});
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  void _json(HttpRequest req, int status, Map<String, dynamic> data) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }
}

class _FakeEnableCoreManager extends CoreManager {
  bool nextEnableResult = true;
  int enableCalls = 0;

  _FakeEnableCoreManager({
    required AppStateModel appState,
    required Stream<List<ConnectivityResult>> connectivityStream,
  }) : super(
          '127.0.0.1:1',
          null,
          'tok',
          () {},
          appState: appState,
          connectivityStream: connectivityStream,
          checkConnectivity: () async => [ConnectivityResult.wifi],
          isWindowsOverride: true,
        );

  @override
  Future<bool> enableWindowsService() async {
    enableCalls++;
    if (nextEnableResult) {
      appState.updateWindowsLimitedMode(false);
    }
    return nextEnableResult;
  }

  @override
  Future<Setting> getSetting() async => Setting(mode: ProxyMode.system);

  @override
  Future<List<String>> getSettingInterfaces() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HttpOverrides? prevOverrides;

  setUpAll(() async {
    installTestEnv();
    prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    await TranslationCache.load();
  });

  tearDownAll(() {
    HttpOverrides.global = prevOverrides;
  });

  group('Windows startup elevation & graceful UAC-cancelled fallback', () {
    late Directory tempDir;
    late File bundledCore;
    late String bundledSha;
    late String metaPath;
    late _FakeServiceAndCore fake;
    late StreamController<List<ConnectivityResult>> connectivity;
    late AppStateModel appState;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lux_win_startup_');
      bundledCore = File('${tempDir.path}/lux_core.exe');
      await bundledCore.writeAsBytes(utf8.encode('lux-core-v1.50.124'));
      bundledSha = sha256.convert(await bundledCore.readAsBytes()).toString();
      metaPath = '${tempDir.path}/service.json';
      fake = _FakeServiceAndCore(bundledSha);
      await fake.start();
      connectivity = StreamController<List<ConnectivityResult>>.broadcast();
      appState = AppStateModel(ThemeMode.light, const Locale('en'));
    });

    tearDown(() async {
      await fake.close();
      await connectivity.close();
      await tempDir.delete(recursive: true);
    });

    test(
        '(a) first-open service install in System mode prompts ONCE, then next start uses zero UAC',
        () async {
      fake.mode = 'system';
      bool persistedDeclined = false;
      int uacPrompts = 0;

      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"PC\\user","S-1-5-21-1-2-3-1001"', '');
        }
        if (exe == 'powershell.exe') {
          uacPrompts++;
          await fake.writeServiceMeta(metaPath);
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final svcClient =
          WindowsServiceClient(metaPath: metaPath, runProcess: fakeRun);
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=${fake.corePort}',
          '-secret=secret-123',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: svcClient,
      );

      final core = CoreManager(
        fake.coreBaseUrl,
        pm,
        'secret-123',
        () {},
        appState: appState,
        connectivityStream: connectivity.stream,
        checkConnectivity: () async => [ConnectivityResult.wifi],
        pingTimeout: const Duration(seconds: 3),
        pingRetryDelay: const Duration(milliseconds: 20),
        isWindowsOverride: true,
        readProxyModeFn: () async => ProxyMode.system,
        readServiceDeclinedFn: () async => persistedDeclined,
        writeServiceDeclinedFn: (v) async => persistedDeclined = v,
      );
      addTearDown(core.dispose);

      // 1st launch in System mode: elevates ONCE to install LuxCoreService
      await core.startInitialCore();
      expect(uacPrompts, 1);
      expect(fake.startCoreCalls, 1);
      expect(fake.isAdmin, isTrue);
      expect(persistedDeclined, isFalse);
      expect(appState.windowsLimitedMode, isFalse);

      // 2nd launch (restart/reboot) in System mode: ZERO UAC prompts!
      await core.startInitialCore();
      expect(uacPrompts, 1,
          reason: 'Must launch via LuxCoreService with zero UAC after install');
      expect(fake.startCoreCalls, 2);
      expect(appState.windowsLimitedMode, isFalse);
    });

    test(
        '(b) UAC-cancelled fallback starts non-elevated System mode, sets banner state, and does NOT nag on next start',
        () async {
      fake.mode = 'mixed'; // even if saved mode was Mixed!
      bool persistedDeclined = false;
      int uacPrompts = 0;
      int nonElevatedLaunches = 0;

      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"PC\\user","S-1-5-21-1-2-3-1001"', '');
        }
        if (exe == 'powershell.exe') {
          final encIdx = args.indexOf('-EncodedCommand') + 1;
          final bytes = base64Decode(args[encIdx]);
          final units = <int>[
            for (int i = 0; i + 1 < bytes.length; i += 2)
              bytes[i] | (bytes[i + 1] << 8)
          ];
          final script = String.fromCharCodes(units);
          if (script.contains('-Verb RunAs')) {
            uacPrompts++;
            return ProcessResult(1, 1223, '', 'canceled');
          }
          nonElevatedLaunches++;
          fake.coreAlive = true;
          fake.isAdmin = false;
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final svcClient =
          WindowsServiceClient(metaPath: metaPath, runProcess: fakeRun);
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=${fake.corePort}',
          '-secret=secret-123',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: svcClient,
      );

      int readyCount = 0;
      final core = CoreManager(
        fake.coreBaseUrl,
        pm,
        'secret-123',
        () => readyCount++,
        appState: appState,
        connectivityStream: connectivity.stream,
        checkConnectivity: () async => [ConnectivityResult.wifi],
        pingTimeout: const Duration(seconds: 3),
        pingRetryDelay: const Duration(milliseconds: 20),
        isWindowsOverride: true,
        readProxyModeFn: () async => ProxyMode.mixed,
        readServiceDeclinedFn: () async => persistedDeclined,
        writeServiceDeclinedFn: (v) async => persistedDeclined = v,
      );
      addTearDown(core.dispose);

      // 1st launch: user cancels UAC -> graceful fallback (NO exception!)
      await core.startInitialCore();
      expect(uacPrompts, 1);
      expect(nonElevatedLaunches, 1);
      expect(readyCount, 1);
      expect(persistedDeclined, isTrue);
      expect(appState.windowsLimitedMode, isTrue);
      expect(fake.isAdmin, isFalse);
      expect(fake.mode, 'system',
          reason: 'Saved Mixed mode must revert to System so browsing works');

      // Verify browsing (System mode start) works immediately without 403!
      await core.start();
      expect(fake.isStarted, isTrue);

      // 2nd launch (simulated reboot / app restart): ZERO repeat UAC nag!
      fake.coreAlive = false;
      fake.isStarted = false;
      await core.startInitialCore();
      expect(uacPrompts, 1,
          reason: 'Must NOT show UAC popup again after user previously declined');
      expect(nonElevatedLaunches, 2);
      expect(appState.windowsLimitedMode, isTrue);
    });

    test(
        '(c) re-enabling via enableWindowsService() installs service, clears banner & flag, and preserves connection',
        () async {
      fake.mode = 'system';
      fake.coreAlive = true;
      fake.isAdmin = false;
      fake.isStarted = true;
      bool persistedDeclined = true;
      appState.updateWindowsLimitedMode(true);
      bool allowUac = false;
      int uacPrompts = 0;

      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"PC\\user","S-1-5-21-1-2-3-1001"', '');
        }
        if (exe == 'powershell.exe') {
          final encIdx = args.indexOf('-EncodedCommand') + 1;
          final bytes = base64Decode(args[encIdx]);
          final units = <int>[
            for (int i = 0; i + 1 < bytes.length; i += 2)
              bytes[i] | (bytes[i + 1] << 8)
          ];
          final script = String.fromCharCodes(units);
          if (script.contains('-Verb RunAs')) {
            uacPrompts++;
            if (!allowUac) return ProcessResult(1, 1223, '', 'canceled');
            await fake.writeServiceMeta(metaPath);
            return ProcessResult(0, 0, '', '');
          }
          // Non-elevated recovery spawn
          fake.coreAlive = true;
          fake.isAdmin = false;
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final svcClient =
          WindowsServiceClient(metaPath: metaPath, runProcess: fakeRun);
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=${fake.corePort}',
          '-secret=secret-123',
        ],
        false,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: svcClient,
      );

      final core = CoreManager(
        fake.coreBaseUrl,
        pm,
        'secret-123',
        () {},
        appState: appState,
        connectivityStream: connectivity.stream,
        checkConnectivity: () async => [ConnectivityResult.wifi],
        pingTimeout: const Duration(seconds: 3),
        pingRetryDelay: const Duration(milliseconds: 20),
        isWindowsOverride: true,
        readProxyModeFn: () async => ProxyMode.system,
        readServiceDeclinedFn: () async => persistedDeclined,
        writeServiceDeclinedFn: (v) async => persistedDeclined = v,
      );
      addTearDown(core.dispose);

      // 1st click "Enable now" but user cancels UAC again -> stays connected in System mode
      final firstAttempt = await core.enableWindowsService();
      expect(firstAttempt, isFalse);
      expect(uacPrompts, 1);
      expect(persistedDeclined, isTrue);
      expect(appState.windowsLimitedMode, isTrue);
      expect(fake.isStarted, isTrue,
          reason: 'Must reconnect System mode after cancelled Enable now');

      // 2nd click "Enable now" and user approves UAC -> service installed, banner cleared, still connected!
      allowUac = true;
      final secondAttempt = await core.enableWindowsService();
      expect(secondAttempt, isTrue);
      expect(uacPrompts, 2);
      expect(fake.startCoreCalls, 1);
      expect(fake.isAdmin, isTrue);
      expect(persistedDeclined, isFalse);
      expect(appState.windowsLimitedMode, isFalse);
      expect(fake.isStarted, isTrue);
    });

    test(
        'switching to Mixed in Settings while disconnected re-triggers service UAC and clears limited mode',
        () async {
      fake.mode = 'system';
      fake.coreAlive = true;
      fake.isAdmin = false;
      fake.isStarted = false;
      bool persistedDeclined = true;
      appState.updateWindowsLimitedMode(true);

      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"PC\\user","S-1-5-21-1-2-3-1001"', '');
        }
        if (exe == 'powershell.exe') {
          await fake.writeServiceMeta(metaPath);
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final svcClient =
          WindowsServiceClient(metaPath: metaPath, runProcess: fakeRun);
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=${fake.corePort}',
          '-secret=secret-123',
        ],
        false,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: svcClient,
      );

      final core = CoreManager(
        fake.coreBaseUrl,
        pm,
        'secret-123',
        () {},
        appState: appState,
        connectivityStream: connectivity.stream,
        checkConnectivity: () async => [ConnectivityResult.wifi],
        pingTimeout: const Duration(seconds: 3),
        pingRetryDelay: const Duration(milliseconds: 20),
        isWindowsOverride: true,
        readProxyModeFn: () async => ProxyMode.system,
        readServiceDeclinedFn: () async => persistedDeclined,
        writeServiceDeclinedFn: (v) async => persistedDeclined = v,
      );
      addTearDown(core.dispose);

      await core.saveSetting(Setting(mode: ProxyMode.mixed));
      expect(fake.startCoreCalls, 1);
      expect(fake.isAdmin, isTrue);
      expect(fake.mode, 'mixed');
      expect(persistedDeclined, isFalse);
      expect(appState.windowsLimitedMode, isFalse);
    });

    test(
        'pre-installed LuxCoreService (e.g. from elevated installer) clears prior serviceDeclined with zero UAC',
        () async {
      await fake.writeServiceMeta(metaPath);
      bool persistedDeclined = true;
      appState.updateWindowsLimitedMode(true);
      int uacCalls = 0;

      Future<ProcessResult> fakeRun(String exe, List<String> args,
          {bool runInShell = false}) async {
        if (exe == 'whoami.exe') {
          return ProcessResult(0, 0, '"PC\\user","S-1-5-21-1-2-3-1001"', '');
        }
        uacCalls++;
        return ProcessResult(0, 0, '', '');
      }

      final svcClient =
          WindowsServiceClient(metaPath: metaPath, runProcess: fakeRun);
      final pm = ProcessManager(
        bundledCore.path,
        [
          r'-home_dir="C:\Users\user\AppData\Roaming\com.github.igoogolx\lux\1.0"',
          '-port=${fake.corePort}',
          '-secret=secret-123',
        ],
        true,
        isWindowsOverride: true,
        runProcess: fakeRun,
        serviceClient: svcClient,
      );

      final core = CoreManager(
        fake.coreBaseUrl,
        pm,
        'secret-123',
        () {},
        appState: appState,
        connectivityStream: connectivity.stream,
        checkConnectivity: () async => [ConnectivityResult.wifi],
        pingTimeout: const Duration(seconds: 3),
        pingRetryDelay: const Duration(milliseconds: 20),
        isWindowsOverride: true,
        readProxyModeFn: () async => ProxyMode.system,
        readServiceDeclinedFn: () async => persistedDeclined,
        writeServiceDeclinedFn: (v) async => persistedDeclined = v,
      );
      addTearDown(core.dispose);

      await core.startInitialCore();
      expect(uacCalls, 0);
      expect(fake.startCoreCalls, 1);
      expect(persistedDeclined, isFalse);
      expect(appState.windowsLimitedMode, isFalse);
    });
  });

  group('WindowsServiceBanner & Settings Background Service UI', () {
    testWidgets('banner renders in EN/PT-BR/ES and Enable now clears it',
        (tester) async {
      final connectivity = StreamController<List<ConnectivityResult>>.broadcast();
      final appState = AppStateModel(ThemeMode.light, const Locale('en'))
        ..updateWindowsLimitedMode(true);
      final core = _FakeEnableCoreManager(
        appState: appState,
        connectivityStream: connectivity.stream,
      );
      addTearDown(() async {
        core.dispose();
        await connectivity.close();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateModel>.value(
          value: appState,
          child: MaterialApp(
            home: Scaffold(
              body: WindowsServiceBanner(coreManager: core),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // English text visible
      expect(find.byKey(const Key('windows_limited_mode_banner')), findsOneWidget);
      expect(find.textContaining('Working normally: web browsers'), findsOneWidget);
      expect(find.textContaining('iCloud for Windows'), findsOneWidget);
      expect(find.text('Enable now'), findsOneWidget);

      // Portuguese (PT-BR) translation
      appState.updateLocale(const Locale('pt'));
      await tester.pumpAndSettle();
      expect(find.text('Ativar agora'), findsOneWidget);
      expect(find.textContaining('iCloud para Windows'), findsOneWidget);

      // Spanish (ES) translation
      appState.updateLocale(const Locale('es'));
      await tester.pumpAndSettle();
      expect(find.text('Activar ahora'), findsOneWidget);
      expect(find.textContaining('iCloud para Windows'), findsOneWidget);

      // Tapping Enable now clears the banner
      await tester.tap(find.byKey(const Key('windows_banner_enable_btn')));
      await tester.pumpAndSettle();
      expect(core.enableCalls, 1);
      expect(appState.windowsLimitedMode, isFalse);
      expect(find.byKey(const Key('windows_limited_mode_banner')), findsNothing);
    });

    testWidgets(
        'SettingsPage shows Background Service status row and Enable now transitions Limited -> Active',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 750);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final connectivity = StreamController<List<ConnectivityResult>>.broadcast();
      final appState = AppStateModel(ThemeMode.light, const Locale('en'))
        ..updateWindowsLimitedMode(true);
      final core = _FakeEnableCoreManager(
        appState: appState,
        connectivityStream: connectivity.stream,
      );
      addTearDown(() async {
        core.dispose();
        await connectivity.close();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateModel>.value(
          value: appState,
          child: MaterialApp(
            home: Scaffold(
              body: SettingsPage(coreManager: core),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings_windows_service_tile')), findsOneWidget);
      expect(find.text('Limited'), findsOneWidget);
      expect(find.byKey(const Key('settings_windows_service_enable_btn')),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('settings_windows_service_enable_btn')));
      await tester.pumpAndSettle();

      expect(core.enableCalls, 1);
      expect(appState.windowsLimitedMode, isFalse);
      expect(find.text('Active'), findsOneWidget);
      expect(find.byKey(const Key('settings_windows_service_enable_btn')),
          findsNothing);
    });
  });
}
