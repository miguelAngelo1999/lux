import 'dart:io';
import 'package:lux/tr.dart';
import 'package:tray_manager/tray_manager.dart';

Future<void> initSystemTray({bool isConnected = false}) async {
  await trayManager.setIcon(
    Platform.isWindows
        ? 'assets/app_icon.ico'
        : 'assets/tray.icns',
  );
  Menu menu = Menu(
    items: [
      MenuItem(
        key: 'lux',
        label: 'Lux 1.41.0',
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem(
        key: isConnected ? 'disconnect' : 'connect',
        label: isConnected ? 'Disconnect' : 'Connect',
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'open_dashboard',
        label: tr().trayDashboardLabel,
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'exit_app',
        label: tr().exit,
      ),
    ],
  );
  await trayManager.setContextMenu(menu);
  await trayManager.setToolTip(isConnected ? 'Lux — Connected' : 'Lux — Disconnected');
}
