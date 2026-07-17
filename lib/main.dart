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
import 'package:lux/util/t_text.dart';
import 'package:lux/util/utils.dart';
import 'package:lux/widget/error/release_mode_error_widget.dart';
import 'package:window_manager/window_manager.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await notifier.ensureInitialized();
  await TranslationCache.load();

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
      // hidden hides title bar text but keeps the Flutter surface full height.
      // windowButtonVisibility: true shows the traffic lights on macOS.
      // Windows uses custom controls in AppBar so buttons stay false.
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: Platform.isMacOS,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // Explicitly re-apply title bar style after window is ready.
      if (Platform.isMacOS) {
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: true,
        );
      }
      // Guard: if window was left at quick-edit size (e.g. after a crash),
      // reset to normal 800x650 so UI isn't squashed on restart.
      if (Platform.isWindows) {
        final sz = await windowManager.getSize();
        if (sz.width < 500 || sz.height < 400) {
          await windowManager.setSize(const Size(800, 650));
        }
      }
      windowManager.center();
      // macOS: always start silent in tray. Auto-connect runs in background.
      // Window shows only when user clicks tray/dock icon, or on error.
      // Windows with startup arg: same silent behavior.
      var isSilentStart = Platform.isMacOS ||
          (Platform.isWindows && args.contains(launchFromStartupArg));
      if (!isSilentStart) {
        windowManager.show();
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
