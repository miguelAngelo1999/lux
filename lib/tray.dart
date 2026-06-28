import 'dart:io';
import 'package:lux/core/core_config.dart';
import 'package:lux/tr.dart';
import 'package:tray_manager/tray_manager.dart';

Future<void> initSystemTray({
  bool isConnected = false,
  List<ProxyItem> proxies = const [],
  String selectedProxyId = '',
}) async {
  await trayManager.setIcon(
    Platform.isWindows ? 'assets/app_icon.ico' : 'assets/tray.icns',
  );

  // Build proxy switcher submenu
  final proxyItems = proxies.map((p) {
    final isSelected = p.id == selectedProxyId;
    return MenuItem(
      key: 'proxy_select_${p.id}',
      label: isSelected ? '✓ ${p.name}' : '  ${p.name}',
    );
  }).toList();

  // Build quick edit submenu (shows active proxy with tick mark)
  final editItems = proxies
      .where((p) => p.type != 'direct')
      .map((p) {
        final isSelected = p.id == selectedProxyId;
        return MenuItem(
          key: 'proxy_edit_${p.id}',
          label: isSelected ? '✓ ${p.name}' : '  ${p.name}',
        );
      })
      .toList();

  final items = <MenuItem>[
    MenuItem(key: 'lux', label: 'Lux 1.41.0', disabled: true),
    MenuItem.separator(),
    MenuItem(
      key: isConnected ? 'disconnect' : 'connect',
      label: isConnected ? 'Disconnect' : 'Connect',
    ),
    MenuItem.separator(),
  ];

  // Proxy switcher
  if (proxyItems.isNotEmpty) {
    items.add(MenuItem.submenu(
      label: 'Switch Profile',
      submenu: Menu(items: proxyItems),
    ));
  }

  // Quick edit
  if (editItems.isNotEmpty) {
    items.add(MenuItem.submenu(
      label: 'Edit Credentials',
      submenu: Menu(items: editItems),
    ));
  }

  items.addAll([
    MenuItem.separator(),
    MenuItem(key: 'open_dashboard', label: tr().trayDashboardLabel),
    MenuItem.separator(),
    MenuItem(key: 'exit_app', label: tr().exit),
  ]);

  await trayManager.setContextMenu(Menu(items: items));
  await trayManager.setToolTip(isConnected ? 'Lux — Connected' : 'Lux — Disconnected');
}
