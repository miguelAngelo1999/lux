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
      // Silence connection errors (errno 1225 = connection refused) — these are
      // expected during startup while lux_core is initializing its WebSocket server.
      // Showing them as a dialog confuses users with "O computador remoto recusou…"
      if (error.type == DioExceptionType.connectionError) {
        final msg = error.message ?? '';
        if (msg.contains('1225') || msg.contains('refused') ||
            msg.contains('recusou') || msg.contains('connection error')) {
          debugPrint('[startup] suppressed connection error: $msg');
          return true; // handled — don't show to user
        }
      }
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
    // Also silence SocketException connection refused at the global level
    if (error is SocketException) {
      final msg = error.message;
      if (msg.contains('1225') || msg.contains('refused') || msg.contains('recusou')) {
        debugPrint('[startup] suppressed SocketException: $msg');
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

    // Determine silent-start before the callback so it's in scope for runApp.
    // macOS: always start silent. Windows: silent only when launched at startup.
    // NOTE: We do NOT hide inside waitUntilReadyToShow. Hiding the window that
    // early causes macOS to throttle the Dart event loop before Home._init()
    // can call coreProcess.run(), so lux_core never starts until the user
    // clicks the dock icon. Instead, Home._init() hides the window AFTER
    // coreProcess.run() has been called.
    final isSilentStart = Platform.isMacOS ||
        (Platform.isWindows && args.contains(launchFromStartupArg));

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
      // Always show the window on startup so Flutter engine initializes.
      // On macOS Sequoia the engine fails to start when launched hidden.
      // The window starts visible; home.dart hides it after lux_core connects
      // if silentStart is true.
      await windowManager.show();
    });

    final theme = await readTheme();
    final clientMode = await readClientMode();
    final defaultLocaleValue = await getLocale();

    ErrorWidget.builder = (FlutterErrorDetails details) {
      return ReleaseModeErrorWidget(details: details);
    };

    runApp(App(theme, defaultLocaleValue, clientMode, silentStart: isSilentStart));
  } catch (e) {
    await notifier.show("$e");
    exitApp();
  }
}
