import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/pages/proxies_page.dart';
import 'package:lux/l10n/app_localizations.dart';
import '../mock_core_manager.dart';

void main() {
  group('ProxiesPage', () {
    late MockCoreManager mock;

    setUp(() {
      mock = MockCoreManager();
    });

    testWidgets('renders without crashing', (tester) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ProxiesPage(coreManager: mock)),
      ));
      await tester.pump();
      // Should not throw
    });

    testWidgets('shows proxy list after load', (tester) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ProxiesPage(coreManager: mock)),
      ));
      await tester.pumpAndSettle();
      // The mock proxy "Test Proxy" should appear
      expect(find.text('Test Proxy'), findsOneWidget);
    });
  });
}
