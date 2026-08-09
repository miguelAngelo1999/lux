// Shared setup for widget tests that pump a whole page.
//
// testWidgets runs inside a fake-async zone, so a platform channel reply is
// scheduled on the real event loop and never arrives. Any page that awaits a
// plugin therefore sits on its loading spinner forever and pumpAndSettle times
// out. Both plugins Lux touches during page load offer in-process test doubles,
// so installing those keeps everything inside the fake clock.

import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getLibraryPath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;
}

/// Points plugin lookups at a scratch directory and fixed app metadata.
///
/// Returns the scratch directory so a test can inspect or seed what the app
/// wrote. Nothing here touches the real Application Support directory, so a test
/// run cannot disturb an installed copy of Lux.
Directory installTestEnv({String version = '1.50.0'}) {
  final root = Directory.systemTemp.createTempSync('lux_test_');
  PathProviderPlatform.instance = _TempPathProvider(root.path);
  PackageInfo.setMockInitialValues(
    appName: 'Lux',
    packageName: 'com.github.igoogolx.lux',
    version: version,
    buildNumber: '1',
    buildSignature: '',
  );
  return root;
}
