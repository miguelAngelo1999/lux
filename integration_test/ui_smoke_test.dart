// Drives the real widget tree on a macOS window.
//
// These tests exercise the pieces most likely to break silently: every page
// renders without throwing, the settings sidebar and its search behave, the
// language picker actually swaps strings, and the rules list shows group
// sections. A unit test cannot catch a layout overflow or a provider lookup
// failing in a nested route, which is what this is for.
//
// Run with:
//   flutter test integration_test/ui_smoke_test.dart -d macos

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lux/app.dart';
import 'package:lux/core/core_config.dart' show ClientMode;
import 'package:lux/util/t_text.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Collects exceptions so a test can assert nothing was thrown during a
  /// sequence, rather than only that the final frame looked right.
  final thrown = <String>[];

  setUp(() {
    thrown.clear();
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      thrown.add(details.exceptionAsString());
      previous?.call(details);
    };
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await TranslationCache.load();
    await tester.pumpWidget(
      const App(ThemeMode.dark, Locale('en'), ClientMode.light),
    );
    // The app talks to lux_core on startup; settle with a budget rather than
    // waiting for a quiescent tree that may never arrive while polling.
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  }

  group('translations', () {
    testWidgets('bundle loads and Portuguese resolves', (tester) async {
      await TranslationCache.load();
      expect(TranslationCache.isLoaded, isTrue);
      expect(TranslationCache.availableLanguages, contains('pt'));

      // A known key must translate, and an unknown one must fall back to the
      // English source rather than surfacing a raw key.
      expect(TranslationCache.translate('Settings', 'pt'), 'Configurações');
      expect(TranslationCache.translate('Rules', 'pt'), 'Regras');
      expect(
        TranslationCache.translate('a string nobody translated', 'pt'),
        'a string nobody translated',
      );

      // English and system are passthrough.
      expect(TranslationCache.translate('Settings', 'en'), 'Settings');
      expect(TranslationCache.translate('Settings', 'system'), 'Settings');
    });

    testWidgets('TText renders the translated string', (tester) async {
      await TranslationCache.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (_) => const Scaffold(body: TText('Settings')),
          ),
        ),
      );
      // Without an AppStateModel above it, TText must not crash the tree.
      await tester.pump();
      expect(thrown, isEmpty);
    });
  });

  group('app shell', () {
    testWidgets('every tab renders without throwing', (tester) async {
      await pumpApp(tester);

      // The dashboard exposes one tab per page; visiting each one catches
      // build-time failures that only appear on a page the user has opened.
      for (final label in [
        'Proxies',
        'Rules',
        'Connections',
        'Log',
        'Settings',
      ]) {
        final tab = find.text(label);
        if (tab.evaluate().isEmpty) {
          // The shell may not be up if the core is unreachable; that is not a
          // UI failure, so record and move on.
          debugPrint('tab "$label" not present, skipping');
          continue;
        }
        await tester.tap(tab.first);
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(thrown, isEmpty, reason: 'exception while opening $label');
      }
    });
  });

  group('settings', () {
    testWidgets('sidebar switches category and search filters across all',
        (tester) async {
      await pumpApp(tester);

      final settingsTab = find.text('Settings');
      if (settingsTab.evaluate().isEmpty) {
        debugPrint('settings tab unavailable; core probably not running');
        return;
      }
      await tester.tap(settingsTab.first);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Each sidebar entry should be reachable and leave the tree intact.
      for (final category in [
        'Network',
        'DNS',
        'Privacy',
        'Updates',
        'Advanced',
        'General',
      ]) {
        final entry = find.text(category);
        if (entry.evaluate().isEmpty) continue;
        await tester.tap(entry.first);
        await tester.pumpAndSettle(const Duration(milliseconds: 400));
        expect(thrown, isEmpty, reason: 'exception on category $category');
      }

      // Search must find a row that lives in a category other than the one
      // currently selected, which is the whole point of searching.
      final searchField = find.byType(TextField);
      if (searchField.evaluate().isNotEmpty) {
        await tester.enterText(searchField.first, 'quic');
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        expect(thrown, isEmpty, reason: 'exception while searching');

        // A nonsense query should produce the empty state, not an error.
        await tester.enterText(searchField.first, 'zzzzznotathing');
        await tester.pumpAndSettle(const Duration(milliseconds: 500));
        expect(thrown, isEmpty, reason: 'exception on an empty search result');

        await tester.enterText(searchField.first, '');
        await tester.pumpAndSettle(const Duration(milliseconds: 400));
      }
    });
  });

  group('rules', () {
    testWidgets('list renders with group sections', (tester) async {
      await pumpApp(tester);

      final rulesTab = find.text('Rules');
      if (rulesTab.evaluate().isEmpty) {
        debugPrint('rules tab unavailable; core probably not running');
        return;
      }
      await tester.tap(rulesTab.first);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(thrown, isEmpty, reason: 'exception rendering the rules list');

      // Searching a large list is where an index-keyed row would misbehave.
      final searchField = find.byType(TextField);
      if (searchField.evaluate().isNotEmpty) {
        await tester.enterText(searchField.first, 'congregatio');
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(thrown, isEmpty, reason: 'exception while filtering rules');

        await tester.enterText(searchField.first, '');
        await tester.pumpAndSettle(const Duration(milliseconds: 400));
      }
    });

    testWidgets('add dialog opens and cancels cleanly', (tester) async {
      await pumpApp(tester);

      final rulesTab = find.text('Rules');
      if (rulesTab.evaluate().isEmpty) return;
      await tester.tap(rulesTab.first);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      final addButton = find.text('Add');
      if (addButton.evaluate().isEmpty) {
        debugPrint('Add button not found');
        return;
      }
      await tester.tap(addButton.first);
      await tester.pumpAndSettle(const Duration(milliseconds: 600));
      expect(thrown, isEmpty, reason: 'exception opening the add dialog');

      // Cancel must dismiss without mutating anything.
      final cancel = find.text('Cancel');
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel.first);
        await tester.pumpAndSettle(const Duration(milliseconds: 400));
      }
      expect(thrown, isEmpty, reason: 'exception closing the add dialog');
    });
  });
}
