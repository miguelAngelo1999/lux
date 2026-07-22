import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:lux/const/const.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/app_log.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/notifier.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:version/version.dart';
import 'package:win32_registry/win32_registry.dart';
import 'package:yaml/yaml.dart';

Future<String> getHomeDir() async {
  PackageInfo packageInfo = await PackageInfo.fromPlatform();
  final Directory appDocumentsDir = await getApplicationSupportDirectory();
  final Version currentVersion = Version.parse(packageInfo.version);
  return path.join(appDocumentsDir.path, '${currentVersion.major}.0');
}

Future<Map<String, dynamic>> readJsonFile(String filePath) async {
  var input = await File(filePath).readAsString();
  var map = jsonDecode(input);
  if (map is Map<String, dynamic>) {
    return map;
  }
  return {};
}

void exitApp() async {
  exit(0);
}

Future<void> setAutoConnect(CoreManager? coreManager) async {
  var isAutoConnect = await readAutoConnect();
  appLog('CORE', 'setAutoConnect isAutoConnect=$isAutoConnect');
  if (isAutoConnect) {
    // Give Go-side auto-connect a short window to fire (it typically connects in 1-3s).
    // Then check immediately — if already connected, skip Flutter-side start().
    await Future.delayed(const Duration(seconds: 5));
    
    // Check if lux_core already auto-connected (Go-side auto-connect)
    try {
      final alreadyStarted = await coreManager?.getIsStarted() ?? false;
      if (alreadyStarted) {
        appLog('CORE', 'setAutoConnect: lux_core already connected (Go-side auto-connect), skipping');
        return;
      }
    } catch (_) {
      // If we can't check, proceed with normal retry logic
    }
    // Try immediately, then retry up to 5 times with increasing delay
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        appLog('CORE', 'setAutoConnect attempt $attempt calling start()');
        await coreManager?.start();
        appLog('CORE', 'setAutoConnect start() succeeded');
        notifier.show(tr().connectOnOpenMsg);
        return; // Success — stop retrying
      } catch (e) {
        String errorDetail = e.toString();
        bool is500 = false;
        if (e is DioException && e.response != null) {
          errorDetail = 'HTTP ${e.response!.statusCode}: ${e.response!.data}';
          is500 = e.response!.statusCode == 500;
        }
        appLog('CORE', 'setAutoConnect attempt $attempt failed: $errorDetail');

        // On Windows, repeated 500s on start() mean lux_core has stale internal
        // state (e.g. TUN adapter left open from previous session). Force stop()
        // to flush that state, then retry. This is the "toggle never comes on"
        // bug after restart. Do this after attempt 1 (give Go one chance first).
        if (is500 && attempt == 1 && Platform.isWindows) {
          appLog('CORE', 'setAutoConnect: 500 on Windows — forcing stop() to clear stale state');
          try {
            await coreManager?.stop();
            await Future.delayed(const Duration(seconds: 2));
          } catch (_) {}
          continue; // retry start() immediately after stop
        }

        if (attempt < 4) {
          // Wait before retrying: 500ms, 1s, 2s, 4s
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
        } else {
          // Final failure
          String? msg = e.toString();
          if (e is DioException) {
            msg = e.message;
          }
          notifier.show(tr().connectOnOpenErrMsg(msg.toString()));
        }
      }
    }
  }
}

Future<void> setAutoLaunch(CoreManager? coreManager) async {
  try {
    var isAutoLaunch = await readAutoLaunch();
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    launchAtStartup.setup(
      appName: packageInfo.appName,
      appPath: Platform.resolvedExecutable,
      args: [launchFromStartupArg],
    );
    var isEnabled = await launchAtStartup.isEnabled();
    if (isAutoLaunch && !isEnabled) {
      await launchAtStartup.enable();
      return;
    }
    if (isEnabled && !isAutoLaunch) {
      await launchAtStartup.disable();
    }
  } catch (e) {
    notifier.show(tr().setAutoLaunchErrMsg(e));
  }
}

Locale convertLocale(String locale) {
  switch (locale) {
    case 'en':
    case 'en-US':
      return const Locale('en');
    case 'zh-CN':
    case 'zh':
      return const Locale('zh');
    case 'fil':
      return const Locale('fil');
    case 'es':
      return const Locale('es');
    case 'fr':
      return const Locale('fr');
    case 'pt':
      return const Locale('pt');
    case 'ar':
      return const Locale('ar');
    case 'de':
      return const Locale('de');
    case 'ja':
      return const Locale('ja');
    case 'ko':
      return const Locale('ko');
    default:
      final curLocale = Intl.getCurrentLocale();
      if (curLocale.startsWith('zh')) return const Locale('zh');
      if (curLocale.startsWith('fil')) return const Locale('fil');
      if (curLocale.startsWith('es')) return const Locale('es');
      if (curLocale.startsWith('fr')) return const Locale('fr');
      if (curLocale.startsWith('pt')) return const Locale('pt');
      if (curLocale.startsWith('ar')) return const Locale('ar');
      if (curLocale.startsWith('de')) return const Locale('de');
      if (curLocale.startsWith('ja')) return const Locale('ja');
      if (curLocale.startsWith('ko')) return const Locale('ko');
      return const Locale('en');
  }
}

Future<Locale> getLocale() async {
  var curLanguage = await readLanguage();
  return convertLocale(curLanguage);
}

typedef InitI10nLabel = ({
  String macOSElevateServiceInfo,
  String macOSNotElevatedMsg
});

Future<InitI10nLabel> getInitI10nLabel() async {
  var locale = await getLocale();

  if (locale == const Locale('zh')) {
    return (
      macOSElevateServiceInfo: "Lux 权限提升服务",
      macOSNotElevatedMsg: "核心没有以 root 身份运行"
    );
  }
  return (
    macOSElevateServiceInfo: "Lux elevation service",
    macOSNotElevatedMsg: "Lux_core is not run as root"
  );
}

Function compareVersion = (String a, String b) {
  var versionA = Version.parse(a);
  var versionB = Version.parse(b);
  return versionA.compareTo(versionB);
};

// Update check is now handled by lib/util/updater.dart (see dashboard.dart).
// This stub is kept so any existing callers compile without changes.
Future<void> checkForUpdate() async {
  // no-op: real check happens via Updater.checkForUpdate() in dashboard
}

String formatBytes(int bytes) {
  var unit = "";
  var value = 0.0;
  if (bytes < 1024 * 1024) {
    value = bytes / 1024;
    unit = "KB";
  } else if (bytes < 1024 * 1024 * 1024) {
    value = bytes / (1024 * 1024);
    unit = "M";
  } else {
    value = (bytes / (1024 * 1024 * 1024));
    unit = "G";
  }
  final fixedNum = value >= 1000 ? 0 : 1;
  return '${value.toStringAsFixed(fixedNum)} $unit';
}

Future<String> getAppVersion() async {
  try {
    String pubspec = File(Paths.pubspec).readAsStringSync();
    final parsed = loadYaml(pubspec);
    if (parsed['version'] is String) {
      final version = parsed['version'] as String;
      return version;
    }
    throw "invalid version";
  } catch (e) {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }
}

void resetSystemProxy() {
  if (!Platform.isWindows) {
    return;
  }
  const keyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  final key = Registry.openPath(
    RegistryHive.currentUser,
    path: keyPath,
    desiredAccessRights: AccessRights.writeOnly,
  );
  const dword = RegistryValue.int32('ProxyEnable', 0);
  key.createValue(dword);
  key.close();
}
