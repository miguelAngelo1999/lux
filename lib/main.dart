import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lux/app.dart';
import 'package:lux/const/const.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/error.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/notifier.dart';
import 'package:lux/util/utils.dart';
import 'package:lux/widget/error/release_mode_error_widget.dart';
import 'package:window_manager/window_manager.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Single-instance guard ────────────────────────────────────────────────
  // Prevents the double-instance that occurs right after an in-app update:
  // the relaunch script opens a new Lux while the old app shell is still
  // dying. The new instance checks the lock file and exits if the existing
  // process is alive.
  if (Platform.isMacOS) {
    try {
      final appDir = Platform.environment['HOME'] ?? '';
      final lockFile = File('$appDir/Library/Application Support/com.github.igoogolx.lux/1.0/lux_app.lock');
      final myPid = pid;
      if (await lockFile.exists()) {
        final content = await lockFile.readAsString();
        final existingPid = int.tryParse(content.trim());
        if (existingPid != null && existingPid != myPid) {
          // Check if the process is actually alive
          final check = await Process.run('kill', ['-0', existingPid.toString()]);
          if (check.exitCode == 0) {
            // Another instance is running — bring it to front and exit
            await Process.run('open', ['-a', '/Applications/Lux.app']);
            exit(0);
          }
        }
      }
      // Write our PID
      await lockFile.writeAsString(myPid.toString());
    } catch (_) {
      // Non-fatal — continue even if lock file can't be written
    }
  }
  // ────────────────────────────────────────────────────────────────────────
  await notifier.ensureInitialized();

  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is DioException) {
      if (error.response?.data is Map<String, dynamic>) {
        final coreHttpError = CoreHttpError.fromJson(error.response?.data);
        if (coreHttpError.code == coreHttpErrorNotElevatedCode) {
          notifier.show(tr().notElevated);
        } else {
          notifier.show(coreHttpError.message);
        }
        return true;
      }
    }
    notifier.show(error.toString());
    return true;
  };

  try {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = WindowOptions(
      size: const Size(800, 650),
      center: true,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: Platform.isMacOS,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (Platform.isMacOS) {
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: true,
        );
      }
      windowManager.center();
      var isLaunchFromStartUp =
          Platform.isWindows && args.contains(launchFromStartupArg);
      if (!isLaunchFromStartUp) {
        windowManager.show();
      } else {
        notifier.show(tr().launchAtStartUpMessage);
      }
    });

    final theme = await readTheme();
    final clientMode = await readClientMode();
    final defaultLocaleValue = await getLocale();

    ErrorWidget.builder = (FlutterErrorDetails details) {
      return ReleaseModeErrorWidget(details: details);
    };

    runApp(App(theme, defaultLocaleValue, clientMode));
  } catch (e) {
    await notifier.show("$e");
    exitApp();
  }
}
