import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native desktop surface capability tier reported by the host window.
///
/// - [liquidGlass]: macOS 26+ `NSGlassEffectView` translucent floating sidebar
///   + behind-window backdrop (when Reduce Transparency is OFF).
/// - [vibrancy]: macOS 12–15 `NSVisualEffectView` `.sidebar` vibrancy.
/// - [opaque]: Windows, Linux, tests, or macOS with Reduce Transparency ON.
enum WindowSurfaceTier {
  liquidGlass,
  vibrancy,
  opaque;

  bool get isTranslucent =>
      this == WindowSurfaceTier.liquidGlass ||
      this == WindowSurfaceTier.vibrancy;

  static WindowSurfaceTier parse(String? raw) {
    switch (raw) {
      case 'liquid_glass':
        return WindowSurfaceTier.liquidGlass;
      case 'vibrancy':
        return WindowSurfaceTier.vibrancy;
      default:
        return WindowSurfaceTier.opaque;
    }
  }
}

/// Bridges Flutter with [MainFlutterWindow]'s `lux_window_surface` channel on
/// macOS while remaining a zero-cost no-op on Windows, Linux, and widget tests.
class WindowSurfaceBridge {
  static const _channel = MethodChannel('lux_window_surface');

  static Future<WindowSurfaceTier> queryTier() async {
    if (!Platform.isMacOS) return WindowSurfaceTier.opaque;
    try {
      final raw = await _channel.invokeMethod<String>('getSurfaceTier');
      return WindowSurfaceTier.parse(raw);
    } catch (_) {
      return WindowSurfaceTier.opaque;
    }
  }

  static Future<void> syncAppearance(ThemeMode mode) async {
    if (!Platform.isMacOS) return;
    final name = switch (mode) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    };
    try {
      await _channel.invokeMethod<void>('setAppearance', {'mode': name});
    } catch (_) {}
  }

  static void listenTierChanges(void Function(WindowSurfaceTier tier) onTier) {
    if (!Platform.isMacOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSurfaceTierChanged') {
        onTier(WindowSurfaceTier.parse(call.arguments as String?));
      }
    });
  }
}
