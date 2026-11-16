import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/util/t_text.dart';
import 'package:provider/provider.dart';

import 'test_env.dart';

class FailingCore extends CoreManager {
  FailingCore({this.shouldFail = true})
      : super('127.0.0.1:1', null, 'test-token', _noop);

  static void _noop() {}

  bool shouldFail;

  @override
  Future<Setting> getSetting() async {
    if (shouldFail) {
      throw DioException(
        requestOptions: RequestOptions(path: '/setting'),
        type: DioExceptionType.connectionError,
        error: const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 61),
          port: 59387,
        ),
      );
    }
    return const Setting();
  }

  @override
  Future<List<String>> getSettingInterfaces() async => ['en0'];

  @override
  Future<void> ensureCoreRunning() async {
    if (shouldFail) {
      throw Exception('still failing');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    installTestEnv();
    await TranslationCache.load();
  });

  testWidgets(
      'settings page shows friendly reconnect banner and retry button on connection refused',
      (tester) async {
    final core = FailingCore(shouldFail: true);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppStateModel(ThemeMode.light, const Locale('en')),
        child: MaterialApp(
          home: Scaffold(body: SettingsPage(coreManager: core)),
        ),
      ),
    );

    // Initial pump runs _load() which catches connection error
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Must show friendly reconnecting UI rather than crashing or showing red snackbar
    expect(find.text('Reconnecting to Lux core...'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    // No red snackbar should be displayed
    expect(find.byType(SnackBar), findsNothing);

    // Revive core and press Retry
    core.shouldFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pumpAndSettle();

    // Now settings are loaded cleanly
    expect(find.text('Auto Launch'), findsOneWidget);
  });
}
