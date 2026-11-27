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

class _FakeDetectCoreManager extends CoreManager {
  _FakeDetectCoreManager({
    required AppStateModel appState,
    required this.proxies,
    required this.detectResult,
    this.certResult = const CertCheckResult(intercepted: false),
  }) : super(
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
  DetectProxyResult detectResult;
  CertCheckResult certResult;

  final List<Map<String, dynamic>> addedPayloads = [];
  int checkCertCalls = 0;

  @override
  Future<ProxyList> getProxyList() async => ProxyList(proxies, '');

  @override
  Future<SubscriptionList> getSubscriptionList() async => SubscriptionList([]);

  @override
  Future<DetectProxyResult> detectProxies() async => detectResult;

  @override
  Future<CertCheckResult> checkCert({
    required String server,
    required int port,
    String username = '',
    String password = '',
  }) async {
    checkCertCalls++;
    return certResult;
  }

  @override
  Future<String> addProxy(Map<String, dynamic> proxy) async {
    final copy = Map<String, dynamic>.from(proxy);
    addedPayloads.add(copy);
    final id = 'p-${addedPayloads.length}';
    proxies = [
      ...proxies,
      ProxyItem.fromJson({
        'id': id,
        'name': copy['name'] ?? '',
        'type': copy['type'] ?? 'http',
        'server': copy['server'] ?? '',
        'port': copy['port'] ?? 0,
        'pacUrl': copy['pacUrl'] ?? '',
      }),
    ];
    return id;
  }
}

Widget _wrapProxiesPage({
  required AppStateModel appState,
  required CoreManager coreManager,
}) {
  return ChangeNotifierProvider<AppStateModel>.value(
    value: appState,
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
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
              coreManager: coreManager,
              curProxyInfo: '',
              dashboardUrl: 'http://127.0.0.1:1',
              onCurProxyInfoChange: (_) {},
            );
          },
        ),
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

  group('DetectProxyResult & DetectedProxy parsing', () {
    test('parses PAC metadata, source, protocol type, and pacOnly', () {
      final result = DetectProxyResult.fromJson({
        'pacUrl': 'http://wpad.corp.local/wpad.dat',
        'pacRuleCount': 14,
        'source': 'dhcp-252',
        'proxies': [
          {
            'host': '10.8.0.1',
            'port': '8082',
            'type': 'http',
            'pacUrl': 'http://wpad.corp.local/wpad.dat',
          },
          {
            'host': '10.8.0.2',
            'port': '1080',
            'type': 'SOCKS',
            'pacUrl': 'http://wpad.corp.local/wpad.dat',
          },
          {
            'host': '',
            'port': '',
            'type': 'http',
            'pacUrl': 'http://wpad.corp.local/wpad.dat',
            'pacOnly': true,
          },
        ],
        'message': '',
      });

      expect(result.hasPac, isTrue);
      expect(result.pacUrl, 'http://wpad.corp.local/wpad.dat');
      expect(result.pacRuleCount, 14);
      expect(result.source, 'dhcp-252');
      expect(result.proxies, hasLength(3));

      expect(result.proxies[0].type, 'http');
      expect(result.proxies[0].isPacOnly, isFalse);
      expect(result.proxies[0].displayName, '10.8.0.1:8082');

      expect(result.proxies[1].type, 'socks5');
      expect(result.proxies[1].displayName, '10.8.0.2:1080');

      expect(result.proxies[2].isPacOnly, isTrue);
      expect(result.proxies[2].displayName, 'PAC (wpad.corp.local)');
    });
  });

  group('suggestDetectedProxyName', () {
    test('uses bump cert O= when SSL interception is detected', () {
      final name = suggestDetectedProxyName(
        certResult: const CertCheckResult(
          intercepted: true,
          issuer: 'CN=Corporate Inspection CA, O=Acme Corp, C=US',
        ),
        existingNames: const [],
      );
      expect(name, 'Acme Corp');
    });

    test('falls back to CN= when bump cert has no O=', () {
      final name = suggestDetectedProxyName(
        certResult: const CertCheckResult(
          intercepted: true,
          issuer: 'CN=Campus Firewall CA, C=BR',
        ),
        existingNames: const [],
      );
      expect(name, 'Campus Firewall CA');
    });

    test('deduplicates bump cert name against existing proxies', () {
      final name = suggestDetectedProxyName(
        certResult: const CertCheckResult(
          intercepted: true,
          issuer: 'O=Acme Corp, CN=Root',
        ),
        existingNames: const ['acme corp', 'Acme Corp 2'],
      );
      expect(name, 'Acme Corp 3');
    });

    test('defaults to Proxy 1 (never server IP) when not intercepted', () {
      expect(
        suggestDetectedProxyName(
          certResult: const CertCheckResult(
            intercepted: false,
            issuer: 'O=DigiCert Inc, CN=DigiCert Global G2',
          ),
          existingNames: const [],
        ),
        'Proxy 1',
      );
    });

    test('defaults to sequential Proxy 1 / Proxy 2 / Proxy 3 when bump cert has no usable name', () {
      expect(
        suggestDetectedProxyName(
          certResult: const CertCheckResult(
            intercepted: true,
            issuer: 'CN=10.8.0.1',
          ),
          existingNames: const ['Office'],
        ),
        'Proxy 1',
      );
      expect(
        suggestDetectedProxyName(
          certResult: const CertCheckResult(
            intercepted: true,
            issuer: 'O=localhost',
          ),
          existingNames: const ['Proxy 1', 'Office'],
        ),
        'Proxy 2',
      );
      expect(
        suggestDetectedProxyName(
          certResult: null,
          existingNames: const ['proxy 1', 'PROXY 2'],
        ),
        'Proxy 3',
      );
    });

    test('uniqueProxyName increments numbered names cleanly without "Proxy 1 2"', () {
      final taken = <String>{'proxy 1'};
      expect(uniqueProxyName('Proxy 1', taken), 'Proxy 2');
      expect(uniqueProxyName('Proxy 1', taken), 'Proxy 3');
      expect(uniqueProxyName('Office', taken), 'Office');
      expect(uniqueProxyName('Office', taken), 'Office 2');
    });
  });

  group('ProxiesPage auto-detection UI flow', () {
    testWidgets('preserves detected PAC URL and suggests Proxy 2 when no bump cert', (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeDetectCoreManager(
        appState: appState,
        proxies: [
          ProxyItem.fromJson({
            'id': 'existing-1',
            'name': 'Proxy 1',
            'type': 'http',
            'server': '192.168.1.1',
            'port': 3128,
          }),
        ],
        detectResult: const DetectProxyResult(
          pacUrl: 'http://wpad.corp.local/wpad.dat',
          pacRuleCount: 8,
          source: 'wpad-probe',
          proxies: [
            DetectedProxy(
              host: '10.8.0.1',
              port: '8082',
              type: 'http',
              pacUrl: 'http://wpad.corp.local/wpad.dat',
            ),
          ],
          message: '',
        ),
        certResult: const CertCheckResult(intercepted: false),
      );

      await tester.pumpWidget(_wrapProxiesPage(appState: appState, coreManager: core));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Detect Proxy'));
      await tester.pumpAndSettle();

      expect(find.text('Detected Proxies'), findsOneWidget);
      expect(find.text('WPAD auto-discovery'), findsOneWidget);
      expect(find.text('http://wpad.corp.local/wpad.dat'), findsOneWidget);
      expect(find.text('8 PAC rules'), findsOneWidget);
      expect(find.text('10.8.0.1:8082'), findsOneWidget);

      await tester.tap(find.text('Add Proxy'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Name this proxy'), findsOneWidget);
      final nameField = tester.widget<TextField>(find.byType(TextField));
      expect(nameField.controller!.text, 'Proxy 2');

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(core.addedPayloads, hasLength(1));
      expect(core.addedPayloads.first['name'], 'Proxy 2');
      expect(core.addedPayloads.first['server'], '10.8.0.1');
      expect(core.addedPayloads.first['port'], 8082);
      expect(core.addedPayloads.first['type'], 'http');
      expect(core.addedPayloads.first['pacUrl'], 'http://wpad.corp.local/wpad.dat');
    });

    testWidgets('handles pure PAC-only script with no static host and names it Proxy 1', (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeDetectCoreManager(
        appState: appState,
        proxies: [],
        detectResult: const DetectProxyResult(
          pacUrl: 'http://pac.example.org/proxy.pac',
          pacRuleCount: 5,
          source: 'dhcp-252',
          proxies: [
            DetectedProxy(
              host: '',
              port: '',
              type: 'http',
              pacUrl: 'http://pac.example.org/proxy.pac',
              pacOnly: true,
            ),
          ],
          message: '',
        ),
      );

      await tester.pumpWidget(_wrapProxiesPage(appState: appState, coreManager: core));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Detect Proxy'));
      await tester.pumpAndSettle();

      expect(find.text('Detected PAC Script'), findsOneWidget);
      expect(find.text('DHCP Option 252'), findsOneWidget);
      expect(find.text('http://pac.example.org/proxy.pac'), findsOneWidget);

      await tester.tap(find.text('Add PAC Proxy'));
      await tester.pumpAndSettle();

      expect(find.text('Credentials for PAC proxy'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(core.checkCertCalls, 0);
      final nameField = tester.widget<TextField>(find.byType(TextField));
      expect(nameField.controller!.text, 'Proxy 1');

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(core.addedPayloads, hasLength(1));
      expect(core.addedPayloads.first['name'], 'Proxy 1');
      expect(core.addedPayloads.first['server'], '');
      expect(core.addedPayloads.first['port'], 0);
      expect(core.addedPayloads.first['pacUrl'], 'http://pac.example.org/proxy.pac');
    });

    testWidgets('allows toggling PAC-only mode and uses bump cert O= when intercepted', (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeDetectCoreManager(
        appState: appState,
        proxies: [],
        detectResult: const DetectProxyResult(
          pacUrl: 'http://wpad.corp.local/proxy.pac',
          pacRuleCount: 12,
          source: 'os-pac',
          proxies: [
            DetectedProxy(
              host: '10.8.0.1',
              port: '8082',
              type: 'http',
              pacUrl: 'http://wpad.corp.local/proxy.pac',
            ),
          ],
          message: '',
        ),
        certResult: const CertCheckResult(
          intercepted: true,
          issuer: 'CN=Proxy CA, O=Acme Corp, C=US',
        ),
      );

      await tester.pumpWidget(_wrapProxiesPage(appState: appState, coreManager: core));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Detect Proxy'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('PAC-only (dynamic routing)'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add PAC Proxy'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Should probe the extracted HTTP host for bump cert and suggest "Acme Corp"
      expect(core.checkCertCalls, 1);
      final nameField = tester.widget<TextField>(find.byType(TextField));
      expect(nameField.controller!.text, 'Acme Corp');

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // Dismiss the SSL Interception Detected dialog if shown
      if (find.text('Skip').evaluate().isNotEmpty) {
        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();
      }

      expect(core.addedPayloads, hasLength(1));
      expect(core.addedPayloads.first['name'], 'Acme Corp');
      expect(core.addedPayloads.first['server'], '');
      expect(core.addedPayloads.first['port'], 0);
      expect(core.addedPayloads.first['pacUrl'], 'http://wpad.corp.local/proxy.pac');
    });

    testWidgets('shows both Dynamic DNS WPAD and Static IP DHCP PAC options, defaulting to http://wpad/wpad.dat', (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final appState = AppStateModel(ThemeMode.light, const Locale('en'));
      final core = _FakeDetectCoreManager(
        appState: appState,
        proxies: [],
        detectResult: DetectProxyResult.fromJson({
          'pacUrl': 'http://wpad/wpad.dat',
          'pacUrls': [
            {
              'url': 'http://wpad/wpad.dat',
              'source': 'wpad-dns',
              'isDynamic': true,
            },
            {
              'url': 'http://10.60.0.1:80/wpad.dat',
              'source': 'dhcp-252',
              'isDynamic': false,
            },
          ],
          'pacRuleCount': 70,
          'source': 'wpad-dns',
          'proxies': [
            {
              'host': '10.8.0.1',
              'port': '8082',
              'type': 'http',
              'pacUrl': 'http://wpad/wpad.dat',
            },
          ],
          'message': '',
        }),
      );

      await tester.pumpWidget(_wrapProxiesPage(appState: appState, coreManager: core));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Detect Proxy'));
      await tester.pumpAndSettle();

      // Both URLs and their Dynamic DNS / Static IP badges should be visible
      expect(find.text('http://wpad/wpad.dat'), findsOneWidget);
      expect(find.text('http://10.60.0.1:80/wpad.dat'), findsOneWidget);
      expect(find.text('Dynamic DNS'), findsOneWidget);
      expect(find.text('Static IP'), findsOneWidget);

      // Default selection is http://wpad/wpad.dat (Dynamic DNS)
      await tester.tap(find.text('Add Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(core.addedPayloads, hasLength(1));
      expect(core.addedPayloads.first['pacUrl'], 'http://wpad/wpad.dat');
      expect(core.addedPayloads.first['name'], 'Proxy 1');

      // Re-open and explicitly pick the Static IP DHCP option
      await tester.tap(find.text('Detect Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('http://10.60.0.1:80/wpad.dat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(core.addedPayloads, hasLength(2));
      expect(core.addedPayloads[1]['pacUrl'], 'http://10.60.0.1:80/wpad.dat');
      expect(core.addedPayloads[1]['name'], 'Proxy 2');
    });
  });
}
