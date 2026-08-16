import 'package:flutter/material.dart';

class AppStateModel extends ChangeNotifier {
  late ThemeMode _theme;
  late Locale _locale;
  String _selectedProxyId = "";
  bool _isStarted = false;
  // Whether the user has intentionally started the core.
  // The watchdog only restarts when this is true, so a deliberate toggle-off
  // is respected and the app doesn't fight the user.
  bool userWantsRunning = false;

  Locale get locale => _locale;
  ThemeMode get theme => _theme;
  String get selectedProxyId => _selectedProxyId;
  bool get isStarted => _isStarted;

  AppStateModel(this._theme, this._locale);

  void updateTheme(ThemeMode newTheme) {
    _theme = newTheme;
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
}
