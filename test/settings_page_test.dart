// Settings page behaviour and layout.
//
// The sidebar and live search were the parts the previous build got wrong: a
// search only filtered the category you happened to be looking at, and rows
// whose stored value was no longer offered threw on build. These drive the real
// page against a fake core so both are covered without a device.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/util/t_text.dart';
import 'package:provider/provider.dart';

import 'test_env.dart';

class FakeCore extends CoreManager {
  FakeCore({
    Setting? setting,
    this.interfaces = const ['en0', 'en1'],
    this.failSave = false,
  })  : setting = setting ?? const Setting(),
        super('127.0.0.1:1', null, 'test-token', _noop);

  static void _noop() {}

  Setting setting;
  List<String> interfaces;
  bool failSave;

  final List<Setting> saved = [];

  @override
  Future<Setting> getSetting() async => setting;

  @override
  Future<List<String>> getSettingInterfaces() async => List.of(interfaces);

  @override
  Future<void> saveSetting(Setting s) async {
    if (failSave) throw Exception('core refused the write');
    saved.add(s);
    setting = s;
  }
}

Future<void> pumpSettings(
  WidgetTester tester,
  FakeCore core, {
  Size size = const Size(1100, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => AppStateModel(ThemeMode.light, const Locale('en')),
      child: MaterialApp(
        home: Scaffold(body: SettingsPage(coreManager: core)),
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

  group('settings sidebar', () {
    testWidgets('every category is offered', (tester) async {
      await pumpSettings(tester, FakeCore());
      for (final label in [
        'General',
        'Network',
        'DNS',
        'TUN / Mixed',
        'Privacy',
        'Updates',
        'Advanced',
      ]) {
        expect(find.text(label), findsWidgets, reason: '$label missing');
      }
    });

    testWidgets('selecting a category swaps the content', (tester) async {
      await pumpSettings(tester, FakeCore());
      // General is selected on open, so a DNS-only row should not be present.
      expect(find.text('Fake IP'), findsNothing);

      await tester.tap(find.text('DNS').last);
      await tester.pumpAndSettle();
      expect(find.text('Fake IP'), findsWidgets);
      expect(find.text('Hijack DNS'), findsWidgets);
    });
  });

  group('settings search', () {
    // The point of search: find a row without knowing which category holds it.
    testWidgets('matches rows in categories other than the selected one',
        (tester) async {
      await pumpSettings(tester, FakeCore());
      await tester.enterText(find.byType(TextField).first, 'quic');
      await tester.pumpAndSettle();

      expect(find.text('Block QUIC'), findsWidgets);
    });

    testWidgets('a query matching nothing says so rather than showing a blank pane',
        (tester) async {
      await pumpSettings(tester, FakeCore());
      await tester.enterText(
          find.byType(TextField).first, 'zzz-not-a-setting-zzz');
      await tester.pumpAndSettle();

      expect(find.textContaining('No settings match'), findsOneWidget);
    });

    testWidgets('clearing the query restores the category view', (tester) async {
      await pumpSettings(tester, FakeCore());
      await tester.enterText(find.byType(TextField).first, 'quic');
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();

      expect(find.textContaining('No settings match'), findsNothing);
      expect(find.text('General'), findsWidgets);
    });
  });

  group('settings writes', () {
    testWidgets('flipping a switch writes through to the core', (tester) async {
      final core = FakeCore(setting: const Setting(autoLaunch: false));
      await pumpSettings(tester, core);

      await tester.enterText(find.byType(TextField).first, 'launch');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(core.saved, isNotEmpty);
      expect(core.saved.last.autoLaunch, isTrue);
    });

    testWidgets('a rejected write surfaces an error and keeps the stored value',
        (tester) async {
      final core =
          FakeCore(setting: const Setting(autoLaunch: false), failSave: true);
      await pumpSettings(tester, core);

      await tester.enterText(find.byType(TextField).first, 'launch');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(core.saved, isEmpty);
      expect(core.setting.autoLaunch, isFalse);
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  // A fixed-width column holding Material's default 48x48 icon buttons is how
  // the rules page ended up rendering its delete button past the row's edge,
  // where it could not be clicked. Pumping at several widths catches that class
  // of bug rather than waiting for someone to notice a missing control.
  group('layout holds at different window widths', () {
    for (final size in const [
      Size(700, 600),
      Size(900, 700),
      Size(1400, 900),
    ]) {
      testWidgets('settings at ${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        await pumpSettings(tester, FakeCore(), size: size);
        expect(tester.takeException(), isNull);

        for (final category in ['Network', 'DNS', 'Privacy', 'Advanced']) {
          await tester.tap(find.text(category).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: '$category overflows at ${size.width}');
        }
      });
    }
  });
}
