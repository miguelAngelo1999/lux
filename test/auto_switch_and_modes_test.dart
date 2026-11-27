import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/dashboard.dart';
import 'package:lux/home.dart' show applyNetSwitchEvent;
import 'package:lux/l10n/app_localizations.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/theme.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/widget/backup_proxies_dialog.dart';
import 'package:provider/provider.dart';

import 'test_env.dart';

class _FakeModeCoreManager extends CoreManager {
  _FakeModeCoreManager({required AppStateModel appState})
      : super(
          '127.0.0.1:1',
          null,
          'test-token',
          _noop,
          appState: appState,
          connectivityStream: const Stream.empty(),
          checkConnectivity: () async => [ConnectivityResult.wifi],
        );

  static void _noop() {}

  bool stayConnectedValue = false;
  String backupModeValue = 'all';
  List<String> backupIdsValue = [];

  final List<ProxyItem> proxies = [
    ProxyItem.fromJson({
      'id': 'p1',
      'name': 'Office Main',
      'type': 'http',
      'server': '10.8.0.1',
      'port': 8082,
    }),
    ProxyItem.fromJson({
      'id': 'p2',
      'name': 'Fleet PAC',
      'type': 'http',
      'server': '',
      'port': 0,
      'pacUrl': 'http://wpad/wpad.dat',
    }),
  ];

  @override
  Future<ProxyList> getProxyList() async => ProxyList(proxies, 'p1');

  @override
  Future<SubscriptionList> getSubscriptionList() async => SubscriptionList([]);

  @override
  Future<RuleList> getRuleList() async => RuleList(['proxy_all', 'bypass_all'], 'proxy_all');

  @override
  Future<bool> getIsStarted() async => false;

  @override
  Future<String> getCurProxyInfo() async => 'Office Main';

  @override
  Future<Setting> getSetting() async => Setting.fromJson({
        'mode': 'mixed',
        'autoLaunch': false,
        'autoConnect': false,
        'defaultInterface': '',
        'localServer': {'port': 1090, 'allowLan': false},
        'hijackDns': {'enabled': true, 'networkService': ''},
        'blockQuic': false,
        'shouldFindProcess': false,
        'dns': {'disableCache': false, 'fakeIp': true},
        'autoMode': {'enabled': false, 'type': 'fallback', 'url': 'https://google.com'},
      });

  @override
  Future<Map<String, dynamic>> getNetSwitchStatus() async => {
        'enabled': false,
        'stayConnected': stayConnectedValue,
        'backupMode': backupModeValue,
        'backupProxyIds': backupIdsValue,
        'state': '',
        'activeProxyName': '',
        'preferredProxyName': '',
        'probing': false,
      };

  @override
  Future<void> setStayConnectedEnabled(bool enabled) async {
    stayConnectedValue = enabled;
  }

  @override
  Future<void> setBackupConfig({
    required String mode,
    required List<String> proxyIds,
  }) async {
    backupModeValue = mode;
    backupIdsValue = List.of(proxyIds);
  }
}

Widget _wrapApp(AppStateModel appState, Widget child) {
  return ChangeNotifierProvider<AppStateModel>.value(
    value: appState,
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: appState.theme,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('pt')],
      home: Builder(
        builder: (ctx) {
          initTr(ctx);
          return child;
        },
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    installTestEnv();
    await TranslationCache.load();
  });

  group('applyNetSwitchEvent failover & return messages', () {
    test('reports failover with preferred and backup names', () {
      final appState = AppStateModel(ThemeMode.dark, const Locale('en'))
        ..userWantsRunning = true;
      final beforeRev = appState.proxyListRevision;

      final msg = applyNetSwitchEvent(
        {
          'state': 'failover',
          'proxyName': 'LP Backup',
          'preferredProxyName': 'Office Main',
        },
        appState,
      );

      expect(msg, "Office Main isn't working — switched to LP Backup");
      expect(appState.proxyListRevision, beforeRev + 1);
    });

    test('reports smooth return to preferred proxy', () {
      final appState = AppStateModel(ThemeMode.dark, const Locale('en'))
        ..userWantsRunning = true;

      final msg = applyNetSwitchEvent(
        {
          'state': 'corporate',
          'proxyName': 'Office Main',
          'returnedToPreferred': true,
        },
        appState,
      );

      expect(msg, 'Office Main is back — switched back');
    });
  });

  group('Simple Mode vs Advanced Mode', () {
    testWidgets('Simple mode hides Rules/Connections/Log and routing dropdown; Advanced restores them',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final appState = AppStateModel(
        ThemeMode.dark,
        const Locale('en'),
        advancedMode: false,
      );
      final core = _FakeModeCoreManager(appState: appState);

      await tester.pumpWidget(
        _wrapApp(appState, Dashboard('/tmp', 'http://127.0.0.1:1', '', core)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Simple mode: only Proxies & Settings tabs visible
      expect(find.byKey(const Key('sidebar-tab-proxies')), findsOneWidget);
      expect(find.byKey(const Key('sidebar-tab-settings')), findsOneWidget);
      expect(find.byKey(const Key('sidebar-tab-rules')), findsNothing);
      expect(find.byKey(const Key('sidebar-tab-connections')), findsNothing);
      expect(find.byKey(const Key('sidebar-tab-log')), findsNothing);

      // Flip to Advanced mode via sidebar pill
      await tester.tap(find.byKey(const Key('sidebar-mode-advanced')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(appState.advancedMode, isTrue);
      expect(find.byKey(const Key('sidebar-tab-rules')), findsOneWidget);
      expect(find.byKey(const Key('sidebar-tab-connections')), findsOneWidget);
      expect(find.byKey(const Key('sidebar-tab-log')), findsOneWidget);

      // Flip back to Simple mode
      await tester.tap(find.byKey(const Key('sidebar-mode-simple')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(appState.advancedMode, isFalse);
      expect(find.byKey(const Key('sidebar-tab-rules')), findsNothing);

      // Dispose Dashboard cleanly so any timers don't linger
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 16));
    });

    testWidgets('Settings hides TUN/DNS/Advanced in Simple mode and shows Fastest proxy + Stay connected in Advanced',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final appState = AppStateModel(
        ThemeMode.dark,
        const Locale('en'),
        advancedMode: false,
      );
      final core = _FakeModeCoreManager(appState: appState);

      await tester.pumpWidget(
        _wrapApp(appState, Scaffold(body: SettingsPage(coreManager: core))),
      );
      await tester.pumpAndSettle();

      // Simple mode: hides TUN, DNS, Advanced filter pills
      expect(find.byKey(const Key('settings-filter-general')), findsOneWidget);
      expect(find.byKey(const Key('settings-filter-network')), findsOneWidget);
      expect(find.byKey(const Key('settings-filter-dns')), findsNothing);
      expect(find.byKey(const Key('settings-filter-tun')), findsNothing);
      expect(find.byKey(const Key('settings-filter-advanced')), findsNothing);

      // Switch to Advanced mode
      appState.updateAdvancedMode(true);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-filter-dns')), findsOneWidget);
      expect(find.byKey(const Key('settings-filter-tun')), findsOneWidget);
      expect(find.byKey(const Key('settings-filter-advanced')), findsOneWidget);

      // Verify renamed Fastest proxy (latency test) in Advanced section
      await tester.tap(find.byKey(const Key('settings-filter-advanced')));
      await tester.pumpAndSettle();
      expect(find.text('Fastest proxy (latency test)'), findsOneWidget);

      // Verify Auto Home/Office + Stay connected + Backup proxies in Network section
      await tester.tap(find.byKey(const Key('settings-filter-network')));
      await tester.pumpAndSettle();
      expect(find.text('Auto Home/Office'), findsOneWidget);
      expect(find.text('Stay connected'), findsOneWidget);
      expect(find.text('Backup proxies'), findsOneWidget);
    });
  });

  group('BackupProxiesDialog', () {
    testWidgets('allows choosing Only selected proxies including PAC-only entries',
        (tester) async {
      final appState = AppStateModel(ThemeMode.dark, const Locale('en'));
      final proxies = [
        ProxyItem.fromJson({
          'id': 'p1',
          'name': 'Office Main',
          'type': 'http',
          'server': '10.8.0.1',
          'port': 8082,
        }),
        ProxyItem.fromJson({
          'id': 'p2',
          'name': 'Fleet PAC',
          'type': 'http',
          'server': '',
          'port': 0,
          'pacUrl': 'http://wpad/wpad.dat',
        }),
      ];

      BackupPoolChoice? result;
      await tester.pumpWidget(
        _wrapApp(
          appState,
          Scaffold(
            body: Builder(
              builder: (ctx) => FilledButton(
                onPressed: () async {
                  result = await showDialog<BackupPoolChoice>(
                    context: ctx,
                    builder: (_) => BackupProxiesDialog(
                      proxies: proxies,
                      initialMode: 'all',
                      initialSelectedIds: const [],
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Only selected proxies'));
      await tester.pumpAndSettle();

      expect(find.text('Fleet PAC'), findsOneWidget);
      expect(find.text('PAC'), findsOneWidget);
      await tester.tap(find.text('Fleet PAC'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.mode, 'selected');
      expect(result!.proxyIds, ['p2']);
    });
  });
}
