import 'package:flutter/material.dart';
import 'package:lux/util/window_surface.dart';

class AppStateModel extends ChangeNotifier {
  late ThemeMode _theme;
  late Locale _locale;
  WindowSurfaceTier _surfaceTier = WindowSurfaceTier.opaque;
  String _selectedProxyId = "";
  bool _isStarted = false;
  // Whether the user has intentionally started the core.
  // The watchdog only restarts when this is true, so a deliberate toggle-off
  // is respected and the app doesn't fight the user.
  bool userWantsRunning = false;
  // Set when Lux was paused automatically due to loss of network connectivity
  // (or woke up offline), so it auto-resumes when connectivity returns.
  bool _pausedForNoNetwork = false;
  bool get pausedForNoNetwork => _pausedForNoNetwork;
  set pausedForNoNetwork(bool value) {
    if (_pausedForNoNetwork == value) return;
    _pausedForNoNetwork = value;
    notifyListeners();
  }

  // Set when lux_core temporarily paused TUN + system proxy so the user can
  // complete a captive-portal Wi-Fi login. While true, the 30s watchdog checks
  // lux_core's live status before skipping so a stuck flag can never disable
  // recovery; manualStop() clears it immediately.
  bool _pausedForCaptivePortal = false;
  DateTime? captivePortalPausedAt;
  bool get pausedForCaptivePortal => _pausedForCaptivePortal;
  set pausedForCaptivePortal(bool value) {
    if (_pausedForCaptivePortal == value) return;
    _pausedForCaptivePortal = value;
    if (value) {
      captivePortalPausedAt ??= DateTime.now();
    } else {
      captivePortalPausedAt = null;
      _captivePortalUrl = null;
    }
    notifyListeners();
  }

  String? _captivePortalUrl;
  String? get captivePortalUrl => _captivePortalUrl;
  set captivePortalUrl(String? value) {
    final normalized = (value != null && value.isNotEmpty) ? value : null;
    if (_captivePortalUrl == normalized) return;
    _captivePortalUrl = normalized;
    notifyListeners();
  }

  // Windows only: true when one-time LuxCoreService admin setup was declined or
  // unavailable and lux_core is running non-elevated in System mode. Drives the
  // non-blocking Dashboard warning banner and Settings status row.
  bool _windowsLimitedMode = false;
  bool get windowsLimitedMode => _windowsLimitedMode;
  void updateWindowsLimitedMode(bool value) {
    if (_windowsLimitedMode == value) return;
    _windowsLimitedMode = value;
    notifyListeners();
  }

  Locale get locale => _locale;
  ThemeMode get theme => _theme;
  WindowSurfaceTier get surfaceTier => _surfaceTier;
  String get selectedProxyId => _selectedProxyId;
  bool get isStarted => _isStarted;

  bool _advancedMode;
  bool get advancedMode => _advancedMode;

  AppStateModel(this._theme, this._locale, {bool advancedMode = true})
      : _advancedMode = advancedMode;

  void updateAdvancedMode(bool value) {
    if (_advancedMode == value) return;
    _advancedMode = value;
    notifyListeners();
  }

  void updateSurfaceTier(WindowSurfaceTier tier) {
    if (tier == _surfaceTier) return;
    _surfaceTier = tier;
    notifyListeners();
  }

  void updateTheme(ThemeMode newTheme) {
    _theme = newTheme;
    WindowSurfaceBridge.syncAppearance(newTheme);
    notifyListeners();
  }

  void updateLocale(Locale newLocale) {
    _locale = newLocale;
    notifyListeners();
  }

  void updateIsStarted(bool newIsStarted) {
    if (newIsStarted == _isStarted) {
      return;
    }
    _isStarted = newIsStarted;
    notifyListeners();
  }

  void updateSelectedProxyId(String newSelectedProxyId) {
    if (newSelectedProxyId == _selectedProxyId) {
      return;
    }
    _selectedProxyId = newSelectedProxyId;
    notifyListeners();
  }

  // Bumped whenever the proxy list changes (add/import/delete) from anywhere
  // in the UI. The proxies page listens and re-fetches so a proxy added from
  // the header bar shows immediately without switching pages.
  int _proxyListRevision = 0;
  int get proxyListRevision => _proxyListRevision;

  void bumpProxyList() {
    _proxyListRevision++;
    notifyListeners();
  }
}
