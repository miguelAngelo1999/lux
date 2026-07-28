import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/tr.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tray_manager/tray_manager.dart';

Future<void> initSystemTray({
  bool isConnected = false,
  List<ProxyItem> proxies = const [],
  String selectedProxyId = '',
}) async {
  await trayManager.setIcon(
    Platform.isWindows ? 'assets/app_icon.ico' : 'assets/tray.icns',
  );

  // Get current version
  String version = '';
  try {
    final info = await PackageInfo.fromPlatform();
    version = info.version;
  } catch (_) {}

  // Find active proxy name
  final activeProxy = proxies.firstWhere(
    (p) => p.id == selectedProxyId,
    orElse: () => ProxyItem('', '', null, null, null, 'direct'),
  );
  final proxyLabel = (isConnected && activeProxy.type != 'direct' && activeProxy.name.isNotEmpty)
      ? '${activeProxy.name}'
      : '';

  // Status line: "Lux 1.46.0 · Connected via Arautos" or "Lux 1.46.0 · Disconnected"
  final statusLabel = isConnected
      ? (proxyLabel.isNotEmpty ? '● $proxyLabel' : '● Connected')
      : '○ Disconnected';
  final versionLabel = version.isNotEmpty ? 'Lux $version' : 'Lux';

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
    MenuItem(key: 'lux_version', label: versionLabel, disabled: true),
    MenuItem(key: 'lux_status', label: statusLabel, disabled: true),
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

  // Debug-only: simulate SSL bump detection for testing the cert install flow
  if (kDebugMode) {
    items.addAll([
      MenuItem.separator(),
      MenuItem(key: 'debug_simulate_ssl_bump', label: '🔬 Simulate SSL Bump (debug)'),
      MenuItem(key: 'debug_simulate_ssl_bump_installed', label: '🔬 Simulate SSL Bump (already installed)'),
    ]);
  }

  await trayManager.setContextMenu(Menu(items: items));
  final tooltip = isConnected
      ? (proxyLabel.isNotEmpty ? 'Lux — $proxyLabel' : 'Lux — Connected')
      : 'Lux — Disconnected';
  await trayManager.setToolTip(tooltip);
}
