import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/l10n/app_localizations.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/proxies_page.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/t_text.dart';
import 'package:provider/provider.dart';

import 'test_env.dart';

class _FakeProxiesCoreManager extends CoreManager {
  _FakeProxiesCoreManager({
    required AppStateModel appState,
    required this.proxies,
    required this.selectedId,
    Map<String, Map<String, dynamic>>? rawDetails,
  })  : rawDetails = rawDetails ?? {},
        super(
          '127.0.0.1:1',
          null,
          'test-token',
          _noop,
          appState: appState,
          connectivityStream: const Stream.empty(),
          checkConnectivity: () async => [ConnectivityResult.wifi],
        );

  static void _noop() {}

  List<ProxyItem> proxies;
  String selectedId;
  Map<String, Map<String, dynamic>> rawDetails;

  bool isStartedValue = false;
  int startCalls = 0;
  int checkCertCalls = 0;
  final List<String> testedIds = [];
  final List<({String id, Map<String, dynamic> payload})> updatedPayloads = [];

  ({int delay, bool certError, bool pacOnly, String error}) nextDelayResult =
      (delay: 42, certError: false, pacOnly: false, error: '');

  CertCheckResult nextCertResult = const CertCheckResult(
    intercepted: false,
    error: '',
  );

  @override
  Future<ProxyList> getProxyList() async => ProxyList(proxies, selectedId);

  @override
  Future<SubscriptionList> getSubscriptionList() async => SubscriptionList([]);

  @override
  Future<void> selectProxy(String id) async {
    selectedId = id;
  }

  @override
  Future<void> notifyManualSelect(String proxyId, String proxyName) async {}

  @override
  Future<ProxyDetail?> getProxyDetail(String id) async {
    final raw = rawDetails[id];
    if (raw == null) return null;
    return ProxyDetail.fromJson(Map<String, dynamic>.from(raw));
  }

  @override
  Future<void> updateProxy(String id, Map<String, dynamic> proxy) async {
    final sanitized = Map<String, dynamic>.from(proxy);
    if (sanitized['server'] is String) {
      sanitized['server'] = (sanitized['server'] as String).trim();
    }
    if (sanitized['username'] is String) {
      sanitized['username'] = (sanitized['username'] as String).trim();
    }
    if (sanitized['name'] is String) {
      sanitized['name'] = (sanitized['name'] as String).trim();
    }
    updatedPayloads.add((id: id, payload: sanitized));
    rawDetails[id] = Map<String, dynamic>.from(sanitized);
    proxies = proxies
        .map((p) => p.id == id ? ProxyItem.fromJson(rawDetails[id]!) : p)
        .toList();
  }

  @override
  Future<({int delay, bool certError, bool pacOnly, String error})>
      testProxyDelayDetailed(String id) async {
    testedIds.add(id);
    return nextDelayResult;
  }

  @override
  Future<CertCheckResult> checkCert({
    required String server,
    required int port,
    String username = '',
    String password = '',
  }) async {
    checkCertCalls++;
    return nextCertResult;
  }

  @override
  Future<bool> getIsStarted() async => isStartedValue;

  @override
  Future<void> start() async {
    startCalls++;
    isStartedValue = true;
  }

  @override
  Future<void> stop() async {
    isStartedValue = false;
  }
}

Future<void> _pumpProxiesPage(
  WidgetTester tester, {
  required AppStateModel appState,
  required _FakeProxiesCoreManager core,
  Size size = const Size(900, 720),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider<AppStateModel>.value(
      value: appState,
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en'),
          Locale('pt'),
          Locale('es'),
          Locale('it'),
          Locale('fil'),
          Locale('zh'),
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) {
              initTr(context);
              return ProxiesPage(
                coreManager: core,
                curProxyInfo: '',
                onCurProxyInfoChange: (_) {},
                dashboardUrl: 'http://127.0.0.1:1',
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    installTestEnv();
    await TranslationCache.load();
  });

  group('Inline credentials strip on selected proxy card', () {
    testWidgets(
        'renders on selected http/socks5/PAC proxies, trims username, preserves full fields, toggles eye icon, and triggers test',
        (tester) async {
      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeProxiesCoreManager(
        appState: appState,
        selectedId: 'p-http',
        proxies: [
          ProxyItem('p-http', 'Corp HTTP', 'proxy.corp', 8080, null, 'http',
              username: 'alice', pacUrl: 'http://pac.corp/proxy.pac'),
          ProxyItem('p-socks', 'Work SOCKS', 'socks.corp', 1080, null, 'socks5',
              username: 'bob'),
          ProxyItem('p-pac', 'Auto PAC', null, null, null, 'http',
              username: 'pacuser', pacUrl: 'http://pac.corp/only.pac'),
          ProxyItem('p-ss', 'Shadowsocks', 'ss.example', 8388, null, 'ss'),
        ],
        rawDetails: {
          'p-http': {
            'id': 'p-http',
            'name': 'Corp HTTP',
            'type': 'http',
            'server': 'proxy.corp',
            'port': 8080,
            'username': 'alice',
            'password': 'old-secret',
            'passwordMode': 'timed',
            'passwordTTLMinutes': 120,
            'pacUrl': 'http://pac.corp/proxy.pac',
            'passwordLocked': false,
          },
          'p-socks': {
            'id': 'p-socks',
            'name': 'Work SOCKS',
            'type': 'socks5',
            'server': 'socks.corp',
            'port': 1080,
            'username': 'bob',
            'password': 'socks-secret',
            'passwordLocked': false,
          },
          'p-pac': {
            'id': 'p-pac',
            'name': 'Auto PAC',
            'type': 'http',
            'server': '',
            'port': 0,
            'username': 'pacuser',
            'password': 'pac-secret',
            'pacUrl': 'http://pac.corp/only.pac',
            'passwordLocked': false,
          },
          'p-ss': {
            'id': 'p-ss',
            'name': 'Shadowsocks',
            'type': 'ss',
            'server': 'ss.example',
            'port': 8388,
          },
        },
      );

      await _pumpProxiesPage(tester, appState: appState, core: core);

      // Selected http proxy shows inline strip; unselected/ss do not.
      expect(find.byKey(const Key('inline-auth-strip-p-http')), findsOneWidget);
      expect(find.byKey(const Key('inline-auth-strip-p-socks')), findsNothing);
      expect(find.byKey(const Key('inline-auth-strip-p-pac')), findsNothing);
      expect(find.byKey(const Key('inline-auth-strip-p-ss')), findsNothing);

      // Username, Password, and Save & Test all share the exact 34px height.
      expect(
          tester
              .getSize(find.byKey(const Key('inline-username-p-http')))
              .height,
          34.0);
      expect(
          tester
              .getSize(find.byKey(const Key('inline-password-p-http')))
              .height,
          34.0);
      expect(
          tester
              .getSize(find.byKey(const Key('inline-save-test-p-http')))
              .height,
          34.0);

      // Status banner and Detect Proxy sit on the same top row.
      final bannerRect =
          tester.getRect(find.byKey(const Key('proxies-status-banner')));
      final detectRect =
          tester.getRect(find.byKey(const Key('proxies-detect-button')));
      expect(bannerRect.right <= detectRect.left, isTrue);
      expect((bannerRect.center.dy - detectRect.center.dy).abs() < 12, isTrue);

      // Username pre-populated, password obscured by default.
      final userField = tester.widget<TextField>(
          find.byKey(const Key('inline-username-p-http')));
      expect(userField.controller!.text, 'alice');
      var passField = tester.widget<TextField>(
          find.byKey(const Key('inline-password-p-http')));
      expect(passField.obscureText, isTrue);

      // Eye toggle reveals then hides password.
      await tester.tap(find.byKey(const Key('inline-password-toggle-p-http')));
      await tester.pump();
      passField = tester.widget<TextField>(
          find.byKey(const Key('inline-password-p-http')));
      expect(passField.obscureText, isFalse);
      await tester.tap(find.byKey(const Key('inline-password-toggle-p-http')));
      await tester.pump();
      passField = tester.widget<TextField>(
          find.byKey(const Key('inline-password-p-http')));
      expect(passField.obscureText, isTrue);

      // Edit with leading/trailing spaces on username, new password, and tap Save & Test.
      await tester.enterText(
          find.byKey(const Key('inline-username-p-http')), '  alice.trimmed  ');
      await tester.enterText(
          find.byKey(const Key('inline-password-p-http')), 'new-secret');
      await tester.tap(find.byKey(const Key('inline-save-test-p-http')));
      await tester.pumpAndSettle();

      expect(core.updatedPayloads, hasLength(1));
      final saved = core.updatedPayloads.single;
      expect(saved.id, 'p-http');
      expect(saved.payload['username'], 'alice.trimmed');
      expect(saved.payload['password'], 'new-secret');
      expect(saved.payload['pacUrl'], 'http://pac.corp/proxy.pac');
      expect(saved.payload['passwordMode'], 'timed');
      expect(saved.payload['passwordTTLMinutes'], 120);
      expect(core.testedIds, contains('p-http'));

      // Selecting SOCKS5 shows strip; selecting PAC-only shows strip; selecting SS hides strip.
      await tester.tap(find.text('Work SOCKS'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('inline-auth-strip-p-socks')), findsOneWidget);

      await tester.tap(find.text('Auto PAC'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('inline-auth-strip-p-pac')), findsOneWidget);

      await tester.tap(find.text('Shadowsocks'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('inline-auth-strip-p-ss')), findsNothing);
      // Non-credential proxy (ss) does not show a credentials toggle chip.
      expect(find.byKey(const Key('credentials-toggle-p-ss')), findsNothing);
    });

    testWidgets(
        'expands and edits credentials on an unselected proxy without changing selection, and auto-expands unselected proxy on 407',
        (tester) async {
      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeProxiesCoreManager(
        appState: appState,
        selectedId: 'p-http',
        proxies: [
          ProxyItem('p-http', 'Corp HTTP', 'proxy.corp', 8080, null, 'http',
              username: 'alice'),
          ProxyItem('p-socks', 'Work SOCKS', 'socks.corp', 1080, null, 'socks5',
              username: 'bob'),
        ],
        rawDetails: {
          'p-http': {
            'id': 'p-http',
            'name': 'Corp HTTP',
            'type': 'http',
            'server': 'proxy.corp',
            'port': 8080,
            'username': 'alice',
            'password': 'secret',
            'passwordLocked': false,
          },
          'p-socks': {
            'id': 'p-socks',
            'name': 'Work SOCKS',
            'type': 'socks5',
            'server': 'socks.corp',
            'port': 1080,
            'username': 'bob',
            'password': 'old',
            'passwordLocked': false,
          },
        },
      );

      await _pumpProxiesPage(tester, appState: appState, core: core);

      // Initially p-http is selected & expanded; p-socks is collapsed.
      expect(find.byKey(const Key('inline-auth-strip-p-http')), findsOneWidget);
      expect(find.byKey(const Key('inline-auth-strip-p-socks')), findsNothing);

      // Tap credentials toggle on unselected p-socks -> expands p-socks WITHOUT selecting it.
      await tester.tap(find.byKey(const Key('credentials-toggle-p-socks')));
      await tester.pumpAndSettle();

      expect(core.selectedId, 'p-http');
      expect(find.byKey(const Key('inline-auth-strip-p-socks')), findsOneWidget);

      // Edit & save credentials on unselected p-socks.
      await tester.enterText(
          find.byKey(const Key('inline-username-p-socks')), 'bob.new');
      await tester.enterText(
          find.byKey(const Key('inline-password-p-socks')), 'socks-new');
      await tester.tap(find.byKey(const Key('inline-save-test-p-socks')));
      await tester.pumpAndSettle();

      expect(core.selectedId, 'p-http');
      expect(core.updatedPayloads, hasLength(1));
      expect(core.updatedPayloads.single.id, 'p-socks');
      expect(core.updatedPayloads.single.payload['username'], 'bob.new');
      expect(core.updatedPayloads.single.payload['password'], 'socks-new');
      expect(core.testedIds, contains('p-socks'));

      // Collapse p-socks, then trigger HTTP 407 on its Test button -> auto-expands and focuses password.
      await tester.tap(find.byKey(const Key('credentials-toggle-p-socks')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('inline-auth-strip-p-socks')), findsNothing);

      core.nextDelayResult = (
        delay: -1,
        certError: false,
        pacOnly: false,
        error: 'HTTP 407 Proxy Authentication Required',
      );
      final testButtons = find.widgetWithText(OutlinedButton, 'Test');
      await tester.tap(testButtons.at(1));
      await tester.pumpAndSettle();

      expect(core.selectedId, 'p-http');
      expect(find.byKey(const Key('inline-auth-strip-p-socks')), findsOneWidget);
      final passEditable = tester.widget<EditableText>(find.descendant(
        of: find.byKey(const Key('inline-password-p-socks')),
        matching: find.byType(EditableText),
      ));
      expect(passEditable.focusNode.hasFocus, isTrue);
    });

    testWidgets('respects passwordLocked with Retype action and Enter submit',
        (tester) async {
      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeProxiesCoreManager(
        appState: appState,
        selectedId: 'p-locked',
        proxies: [
          ProxyItem('p-locked', 'Locked Proxy', 'proxy.corp', 8080, null, 'http',
              username: 'lockeduser', passwordLocked: true),
        ],
        rawDetails: {
          'p-locked': {
            'id': 'p-locked',
            'name': 'Locked Proxy',
            'type': 'http',
            'server': 'proxy.corp',
            'port': 8080,
            'username': 'lockeduser',
            'passwordLocked': true,
          },
        },
      );

      await _pumpProxiesPage(tester, appState: appState, core: core);

      // Shows locked placeholder + Retype button, not an editable password field.
      expect(find.byKey(const Key('inline-password-locked-p-locked')),
          findsOneWidget);
      expect(find.byKey(const Key('inline-retype-p-locked')), findsOneWidget);
      expect(find.byKey(const Key('inline-password-p-locked')), findsNothing);

      // Tap Retype -> unlocks typing field and focuses it.
      await tester.tap(find.byKey(const Key('inline-retype-p-locked')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('inline-password-p-locked')), findsOneWidget);
      final passEditable = tester.widget<EditableText>(find.descendant(
        of: find.byKey(const Key('inline-password-p-locked')),
        matching: find.byType(EditableText),
      ));
      expect(passEditable.focusNode.hasFocus, isTrue);

      await tester.enterText(
          find.byKey(const Key('inline-password-p-locked')), 'fresh-pass');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(core.updatedPayloads, hasLength(1));
      expect(core.updatedPayloads.single.payload['password'], 'fresh-pass');
      expect(core.testedIds, contains('p-locked'));
    });

    testWidgets('highlights inline strip and auto-focuses password on HTTP 407',
        (tester) async {
      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeProxiesCoreManager(
        appState: appState,
        selectedId: 'p1',
        proxies: [
          ProxyItem('p1', 'Office Proxy', 'proxy.office', 8080, null, 'http',
              username: 'u1'),
        ],
        rawDetails: {
          'p1': {
            'id': 'p1',
            'name': 'Office Proxy',
            'type': 'http',
            'server': 'proxy.office',
            'port': 8080,
            'username': 'u1',
            'password': 'bad',
            'passwordLocked': false,
          },
        },
      );
      core.nextDelayResult = (
        delay: -1,
        certError: false,
        pacOnly: false,
        error: 'upstream proxy authentication required (HTTP 407)',
      );

      await _pumpProxiesPage(tester, appState: appState, core: core);

      // Tap Test button -> returns 407 authError.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();

      // Inline strip shows error hint and password field is focused.
      expect(find.text('Invalid username or password'), findsWidgets);
      final passEditable = tester.widget<EditableText>(find.descendant(
        of: find.byKey(const Key('inline-password-p1')),
        matching: find.byType(EditableText),
      ));
      expect(passEditable.focusNode.hasFocus, isTrue);

      // Status banner shows state 2 ("Login required...") and action focuses password.
      expect(
          find.text('Login required — check your username and password below'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('inline-username-p1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('banner-action-auth')));
      await tester.pumpAndSettle();
      expect(passEditable.focusNode.hasFocus, isTrue);
    });
  });

  group('Plain-language status banner on ProxiesPage', () {
    testWidgets('covers all 6 banner states, priorities, and narrow layout',
        (tester) async {
      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeProxiesCoreManager(
        appState: appState,
        selectedId: 'p1',
        proxies: [
          ProxyItem('p1', 'Office Proxy', 'proxy.office', 8080, null, 'http',
              username: 'u1'),
        ],
        rawDetails: {
          'p1': {
            'id': 'p1',
            'name': 'Office Proxy',
            'type': 'http',
            'server': 'proxy.office',
            'port': 8080,
            'username': 'u1',
            'password': 'secret',
            'passwordLocked': false,
          },
        },
      );

      // Narrow 680x560 layout must render without any overflow exception.
      await _pumpProxiesPage(
        tester,
        appState: appState,
        core: core,
        size: const Size(680, 560),
      );
      expect(tester.takeException(), isNull);

      // 6. Disconnected -> shows Disconnected + Connect button that starts connection.
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.byKey(const Key('banner-action-connect')), findsOneWidget);
      await tester.tap(find.byKey(const Key('banner-action-connect')));
      await tester.pumpAndSettle();
      expect(core.startCalls, 1);
      expect(appState.isStarted, isTrue);

      // 5. Connected (healthy) -> shows "Connected via Office Proxy".
      expect(find.text('Connected via Office Proxy'), findsOneWidget);

      // Test reachable with latency ms -> shows "42 ms".
      core.nextDelayResult =
          (delay: 42, certError: false, pacOnly: false, error: '');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();
      expect(find.text('Connected via Office Proxy'), findsOneWidget);
      expect(find.text('42 ms'), findsWidgets);

      // Test reachable PAC OK -> shows "PAC OK".
      core.nextDelayResult =
          (delay: 0, certError: false, pacOnly: true, error: '');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();
      expect(find.text('PAC OK'), findsWidgets);

      // 4. Unreachable -> shows "Proxy unreachable on this network" + Test & Detect Proxy.
      core.nextDelayResult = (
        delay: -1,
        certError: false,
        pacOnly: false,
        error: 'dial tcp 10.0.0.1:8080: i/o timeout',
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();
      expect(find.text('Proxy unreachable on this network'), findsOneWidget);
      expect(find.byKey(const Key('banner-action-test')), findsOneWidget);
      expect(find.byKey(const Key('banner-action-detect')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 3. Untrusted CA cert -> shows "Proxy certificate not trusted" + Trust button calling cert trust flow.
      core.nextDelayResult = (
        delay: -1,
        certError: true,
        pacOnly: false,
        error: 'x509: certificate signed by unknown authority',
      );
      await tester.tap(find.byKey(const Key('banner-action-test')));
      await tester.pumpAndSettle();
      expect(find.text('Proxy certificate not trusted'), findsOneWidget);
      await tester.tap(find.byKey(const Key('banner-action-trust')));
      await tester.pumpAndSettle();
      expect(find.text('Trust Certificate'), findsOneWidget);
      await tester.tap(find.text('Trust Certificate'));
      await tester.pumpAndSettle();
      expect(core.checkCertCalls, 1);

      // 1. Paused for no network takes highest priority over other states.
      appState.pausedForNoNetwork = true;
      await tester.pumpAndSettle();
      expect(find.text('Paused — waiting for Wi-Fi or Ethernet'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('New UI string translations', () {
    test('all new strings exist in pt, es, it, fil, zh', () {
      const keys = [
        'Retype',
        'Save & Test',
        'Invalid username or password',
        'Paused — waiting for Wi-Fi or Ethernet',
        'Login required — check your username and password below',
        'Enter password',
        'Proxy certificate not trusted',
        'Trust',
        'Proxy unreachable on this network',
        'Connected via {name}',
        'Connect',
      ];
      for (final lang in ['pt', 'es', 'it', 'fil', 'zh']) {
        for (final key in keys) {
          final translated = TranslationCache.translate(key, lang);
          expect(translated, isNot(equals(key)),
              reason: 'Missing "$key" translation for $lang');
        }
      }
    });
  });
}
