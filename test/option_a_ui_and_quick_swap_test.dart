import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/l10n/app_localizations.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/proxies_page.dart';
import 'package:lux/theme.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/window_surface.dart';
import 'package:lux/widget/app_sidebar.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'test_env.dart';

class _FakeShellCore extends CoreManager {
  _FakeShellCore(AppStateModel appState)
      : super('127.0.0.1:1', null, 'token', _noop, appState: appState);
  static void _noop() {}

  final List<ProxyItem> _proxies = [
    ProxyItem('p1', 'Congregatio House', '10.8.0.1', 8082, null, 'http',
        username: 'miguel.a'),
  ];

  final Map<String, Map<String, dynamic>> _details = {
    'p1': {
      'id': 'p1',
      'name': 'Congregatio House',
      'type': 'http',
      'server': '10.8.0.1',
      'port': 8082,
      'username': 'miguel.a',
      'password': 'secret',
      'passwordLocked': false,
    },
  };

  @override
  Future<Setting> getSetting() async => Setting.fromJson({'mode': 'mixed'});

  @override
  Future<WebSocketChannel?> getTrafficChannel() async => null;

  @override
  Future<ProxyList> getProxyList() async => ProxyList(_proxies, 'p1');

  @override
  Future<SubscriptionList> getSubscriptionList() async => SubscriptionList([]);

  @override
  Future<ProxyDetail?> getProxyDetail(String id) async {
    final raw = _details[id];
    if (raw == null) return null;
    return ProxyDetail.fromJson(Map<String, dynamic>.from(raw));
  }

  @override
  Future<void> updateProxy(String id, Map<String, dynamic> data) async {
    _details[id] = Map<String, dynamic>.from(data);
  }

  @override
  Future<({int delay, bool certError, bool pacOnly, String error})>
      testProxyDelayDetailed(String id) async =>
          (delay: 14, certError: false, pacOnly: false, error: '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    installTestEnv();
    await TranslationCache.load();
  });

  test('WindowSurfaceTier.parse maps native macOS & fallback tiers', () {
    expect(WindowSurfaceTier.parse('liquid_glass'),
        WindowSurfaceTier.liquidGlass);
    expect(WindowSurfaceTier.parse('liquid_glass').isTranslucent, isTrue);
    expect(WindowSurfaceTier.parse('vibrancy'), WindowSurfaceTier.vibrancy);
    expect(WindowSurfaceTier.parse('vibrancy').isTranslucent, isTrue);
    expect(WindowSurfaceTier.parse('opaque'), WindowSurfaceTier.opaque);
    expect(WindowSurfaceTier.parse('opaque').isTranslucent, isFalse);
    expect(WindowSurfaceTier.parse(null), WindowSurfaceTier.opaque);
    expect(WindowSurfaceTier.parse('unknown'), WindowSurfaceTier.opaque);
  });

  test('recordRecentUsername deduplicates, caps at 8, and preserves recency',
      () async {
    const pid = 'recent-test-proxy';
    for (var i = 1; i <= 10; i++) {
      await recordRecentUsername(pid, 'user.$i');
    }
    var list = await readRecentUsernames(pid);
    expect(list.length, 8);
    expect(list.first, 'user.10');
    expect(list.last, 'user.3');

    // Re-recording an older username moves it to the top without duplicating.
    list = await recordRecentUsername(pid, '  user.5  ');
    expect(list.length, 8);
    expect(list.first, 'user.5');
    expect(list.where((u) => u == 'user.5').length, 1);
  });

  testWidgets(
      'AppSidebar renders cleanly across Light/Obsidian Dark and all surface tiers',
      (tester) async {
    tester.view.physicalSize = const Size(800, 650);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const tabs = [
      AppSidebarTab(glyph: LuxGlyph.proxies, label: 'Proxies'),
      AppSidebarTab(glyph: LuxGlyph.rules, label: 'Rules'),
      AppSidebarTab(glyph: LuxGlyph.connections, label: 'Connections'),
      AppSidebarTab(glyph: LuxGlyph.logs, label: 'Log'),
      AppSidebarTab(glyph: LuxGlyph.settings, label: 'Settings'),
    ];

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      for (final tier in WindowSurfaceTier.values) {
        final appState = AppStateModel(mode, const Locale('en'))
          ..updateSurfaceTier(tier)
          ..updateIsStarted(true);
        final core = _FakeShellCore(appState);
        int selected = 0;

        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: appState,
            child: MaterialApp(
              themeMode: mode,
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
              ],
              supportedLocales: const [Locale('en')],
              home: Builder(
                builder: (context) {
                  initTr(context);
                  return StatefulBuilder(
                    builder: (context, setState) => Scaffold(
                      body: Row(
                        children: [
                          AppSidebar(
                            tabs: tabs,
                            selectedIndex: selected,
                            onSelected: (i) => setState(() => selected = i),
                            coreManager: core,
                          ),
                          const Expanded(child: SizedBox()),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('app-sidebar')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-telemetry')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-mode-switcher')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-update-pill')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-theme-toggle')), findsOneWidget);
        expect(find.byKey(const Key('sidebar-privacy-toggle')), findsOneWidget);

        await tester.tap(find.byKey(const Key('sidebar-tab-rules')));
        await tester.pumpAndSettle();
        expect(selected, 1);

        // 1-click Theme toggle flips Light <-> Dark live.
        final beforeTheme = appState.theme;
        await tester.tap(find.byKey(const Key('sidebar-theme-toggle')));
        await tester.pumpAndSettle();
        expect(appState.theme, isNot(beforeTheme));
      }
    }
  });

  testWidgets(
      'Narrow 640x480 minimum window collapses labels cleanly without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final appState = AppStateModel(ThemeMode.dark, const Locale('pt'))
      ..updateSurfaceTier(WindowSurfaceTier.liquidGlass)
      ..updateIsStarted(true);
    final core = _FakeShellCore(appState);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: appState,
        child: MaterialApp(
          themeMode: ThemeMode.dark,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('pt')],
          home: Builder(
            builder: (context) {
              initTr(context);
              return Scaffold(
                body: Row(
                  children: [
                    AppSidebar(
                      tabs: const [
                        AppSidebarTab(glyph: LuxGlyph.proxies, label: 'Proxies'),
                        AppSidebarTab(glyph: LuxGlyph.rules, label: 'Rules'),
                        AppSidebarTab(glyph: LuxGlyph.settings, label: 'Settings'),
                      ],
                      selectedIndex: 0,
                      onSelected: (_) {},
                      coreManager: core,
                      compact: true,
                    ),
                    Expanded(
                      child: ProxiesPage(
                        coreManager: core,
                        curProxyInfo: 'Congregatio House',
                        onCurProxyInfoChange: (_) {},
                        dashboardUrl: 'http://127.0.0.1:9999',
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('proxies-detect-button')), findsOneWidget);
    expect(find.byKey(const Key('proxies-autoswitch-menu')), findsOneWidget);
  });

  testWidgets(
      '1-click recent-username dropdown swaps user inline and opens password retype',
      (tester) async {
    tester.view.physicalSize = const Size(800, 650);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await recordRecentUsername('p1', 'miguel.a');
    await recordRecentUsername('p1', 'joao.b');

    final appState = AppStateModel(ThemeMode.dark, const Locale('en'))
      ..updateIsStarted(true);
    final core = _FakeShellCore(appState);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: appState,
        child: MaterialApp(
          themeMode: ThemeMode.dark,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en')],
          home: Builder(
            builder: (context) {
              initTr(context);
              return Scaffold(
                body: ProxiesPage(
                  coreManager: core,
                  curProxyInfo: 'Congregatio House',
                  onCurProxyInfoChange: (_) {},
                  dashboardUrl: 'http://127.0.0.1:9999',
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Expand inline auth via clickable username pill.
    await tester.tap(find.byKey(const Key('subtitle-username-p1')));
    await tester.pumpAndSettle();

    // Open recent-username switcher dropdown and pick 'joao.b'.
    expect(find.byKey(const Key('inline-username-history-p1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('inline-username-history-p1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('joao.b').last);
    await tester.pumpAndSettle();

    final userField =
        tester.widget<TextField>(find.byKey(const Key('inline-username-p1')));
    expect(userField.controller!.text, 'joao.b');
    // Swapping to another user automatically opens the editable password field.
    expect(find.byKey(const Key('inline-password-p1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
