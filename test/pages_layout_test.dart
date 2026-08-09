// Layout guard for every page, at several window widths.
//
// A fixed-width column holding Material's default 48x48 icon buttons is how the
// rules page came to render its delete control past the row's right edge, where
// it was invisible and unclickable. Nothing failed loudly: the app looked fine
// and a control was simply missing. Pumping each page and asserting no render
// exception catches that whole class of bug.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/connections_page.dart';
import 'package:lux/pages/log_page.dart';
import 'package:lux/pages/rules_page.dart';
import 'package:lux/util/t_text.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'test_env.dart';

/// Serves a populated rule set and no live sockets.
///
/// The log and connections pages must render when their socket cannot be opened,
/// which is the normal state while the core is starting.
class FakeCore extends CoreManager {
  FakeCore() : super('127.0.0.1:1', null, 'test-token', _noop);
  static void _noop() {}

  @override
  Future<List<CustomizedRuleItem>> getCustomizedRules() async => [
        for (var i = 0; i < 8; i++)
          CustomizedRuleItem(
            id: 'r$i',
            slug: 'DOMAIN-SUFFIX-host$i.example.com',
            groupId: i.isEven ? 'g-blocked' : 'g-work',
            ruleType: 'DOMAIN-SUFFIX',
            // Long enough to squeeze the flexible column.
            payload: 'a-fairly-long-hostname-$i.subdomain.example.com',
            policy: i.isEven ? 'REJECT' : 'A Named Proxy',
            disabled: i == 3,
            raw: 'DOMAIN-SUFFIX,host$i.example.com,REJECT',
            network: i == 5 ? 'udp' : '',
            broken: i == 7 ? 'proxy no longer exists' : '',
            order: i,
          ),
      ];

  @override
  Future<List<RuleGroup>> getRuleGroups() async => const [
        RuleGroup(id: 'g-blocked', name: 'Blocked', enabled: true, order: 0),
        RuleGroup(id: 'g-work', name: 'Congregatio intranet', enabled: false, order: 1),
      ];

  @override
  Future<ProxyList> getProxyList() async => ProxyList(
        [ProxyItem('p1', 'A Named Proxy', 'example.com', 443, null, 'http')],
        'local',
      );

  @override
  Future<RuleDiagnostics> getRuleDiagnostics() async => const RuleDiagnostics(
        shadowed: [
          RuleShadow(
            ruleId: 'r1',
            ruleSlug: 'DOMAIN-SUFFIX-host1.example.com',
            shadowedById: 'r0',
            shadowedBySlug: 'DOMAIN-SUFFIX-host0.example.com',
            reason: 'an earlier rule already covers it',
          )
        ],
        broken: [],
      );

  // Both pages must render when the socket cannot be opened, which is the
  // normal state while the core is still starting.
  @override
  Future<WebSocketChannel> getLogChannel() async =>
      throw Exception('core not reachable');

  @override
  Future<WebSocketChannel> getConnectionsChannel() async =>
      throw Exception('core not reachable');
}

Future<void> pumpPage(WidgetTester tester, Widget page, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AppStateModel(ThemeMode.light, const Locale('en')),
      child: MaterialApp(home: Scaffold(body: page)),
    ),
  );
  // pumpAndSettle would hang on an indefinite spinner; fixed pumps are enough
  // to lay out and reveal any overflow.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    installTestEnv();
    await TranslationCache.load();
  });

  const sizes = [
    Size(680, 560), // narrowest the window can be dragged
    Size(900, 700),
    Size(1600, 1000),
  ];

  for (final size in sizes) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('rules page lays out at $label', (tester) async {
      await pumpPage(tester, RulesPage(coreManager: FakeCore()), size);
      expect(tester.takeException(), isNull);
      // Every row control must actually be reachable, not clipped away.
      expect(find.byTooltip('Delete'), findsWidgets);
      expect(find.byTooltip('Edit'), findsWidgets);
    });

    testWidgets('rules page lays out while searching at $label', (tester) async {
      await pumpPage(tester, RulesPage(coreManager: FakeCore()), size);
      await tester.enterText(find.byType(TextField), 'example');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('log page lays out at $label', (tester) async {
      await pumpPage(tester, LogPage(coreManager: FakeCore()), size);
      expect(tester.takeException(), isNull);
    });

    testWidgets('connections page lays out at $label', (tester) async {
      await pumpPage(tester, ConnectionsPage(coreManager: FakeCore()), size);
      expect(tester.takeException(), isNull);
    });
  }
}
