// Widget-level tests that need neither a device nor a running lux_core.
//
// The full-app integration test cannot run while Lux is installed and connected:
// App() spawns its own lux_core, which then collides with the live instance on
// the local proxy port. Testing the pieces directly avoids that entirely and
// still covers the logic that actually broke.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/widget/setting_tiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TranslationCache', () {
    setUpAll(() async {
      await TranslationCache.load();
    });

    test('bundle loads and reports Portuguese', () {
      expect(TranslationCache.isLoaded, isTrue);
      expect(TranslationCache.availableLanguages, contains('pt'));
    });

    test('known strings translate', () {
      expect(TranslationCache.translate('Settings', 'pt'), 'Configurações');
      expect(TranslationCache.translate('Rules', 'pt'), 'Regras');
      expect(TranslationCache.translate('Connections', 'pt'), 'Conexões');
      expect(TranslationCache.translate('Network', 'pt'), 'Rede');
    });

    // An incomplete language has to degrade to English rather than surfacing a
    // raw key, which is why the keys are the English source strings.
    test('unknown strings fall back to the source text', () {
      const missing = 'a string nobody has translated yet';
      expect(TranslationCache.translate(missing, 'pt'), missing);
    });

    test('english and system are passthrough', () {
      expect(TranslationCache.translate('Settings', 'en'), 'Settings');
      expect(TranslationCache.translate('Settings', 'system'), 'Settings');
      expect(TranslationCache.translate('Settings', ''), 'Settings');
    });

    test('an unknown language code falls back rather than throwing', () {
      expect(TranslationCache.translate('Settings', 'xx'), 'Settings');
    });
  });

  group('SettingRow search', () {
    SettingRow row(String title, List<String> keywords) => SettingRow(
          title: title,
          keywords: keywords,
          build: (_) => const SizedBox.shrink(),
        );

    test('an empty query matches everything', () {
      expect(row('Block QUIC', const []).matches(''), isTrue);
    });

    test('matches on the visible title, case-insensitively', () {
      final r = row('Block QUIC', const []);
      expect(r.matches('quic'), isTrue);
      expect(r.matches('BLOCK'), isTrue);
      expect(r.matches('block qu'), isTrue);
    });

    // Keywords are the point: a user searches for the symptom, not the label.
    test('matches on keywords absent from the title', () {
      final r = row('Block QUIC', const ['http3', 'youtube', 'udp']);
      expect(r.matches('youtube'), isTrue);
      expect(r.matches('http3'), isTrue);
    });

    test('does not match unrelated text', () {
      final r = row('Block QUIC', const ['http3']);
      expect(r.matches('telemetry'), isFalse);
    });
  });

  group('setting tiles', () {
    // A stored value absent from the offered options previously threw, which
    // happens when a config carries a value a newer build no longer offers.
    testWidgets('dropdownTile survives a value outside its options',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: dropdownTile<String>(
            title: 'Mode',
            value: 'a-value-no-longer-offered',
            options: const ['one', 'two'],
            label: (v) => v,
            onChanged: (_) {},
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('switchTile reports changes', (tester) async {
      bool? received;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: switchTile(
            title: 'Auto Connect',
            subtitle: 'Connect on launch',
            value: false,
            onChanged: (v) => received = v,
          ),
        ),
      ));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(received, isTrue);
    });

    testWidgets('a null onChanged disables the row', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: switchTile(
            title: 'Auto Connect',
            subtitle: 'Connect on launch',
            value: false,
            onChanged: null,
          ),
        ),
      ));
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.onChanged, isNull);
    });

    // A key derived from the value makes the field adopt an external change
    // instead of keeping whatever it was first built with.
    testWidgets('numberTile picks up an externally changed value',
        (tester) async {
      Widget build(int v) => MaterialApp(
            home: Scaffold(
              body: numberTile(title: 'Port', value: v, onChanged: (_) {}),
            ),
          );

      await tester.pumpWidget(build(1090));
      expect(find.text('1090'), findsOneWidget);

      await tester.pumpWidget(build(8080));
      await tester.pump();
      expect(find.text('8080'), findsOneWidget);
      expect(find.text('1090'), findsNothing);
    });

    testWidgets('actionTile shows progress instead of the button when busy',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => actionTile(
              context: ctx,
              title: 'Check for Updates',
              subtitle: 'v1.50.0',
              buttonLabel: 'Check',
              busy: true,
              onPressed: () {},
            ),
          ),
        ),
      ));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Check'), findsNothing);
    });
  });
}
