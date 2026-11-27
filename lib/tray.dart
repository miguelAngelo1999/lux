import 'dart:io';
import 'package:lux/core/core_config.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/t_text.dart';
import 'package:tray_manager/tray_manager.dart';

String? _cachedTrayVersion;

Future<String> _resolveTrayVersion(String? versionOverride) async {
  if (versionOverride != null && versionOverride.isNotEmpty) {
    return versionOverride;
  }
  _cachedTrayVersion ??= await getAppVersionString();
  return _cachedTrayVersion!;
}

Future<void> initSystemTray({
  bool isConnected = false,
  List<ProxyItem> proxies = const [],
  String selectedProxyId = '',
  String? appVersion,
  String? languageCode,
}) async {
  final version = await _resolveTrayVersion(appVersion);
  final lang = languageCode ?? await readLocale();
  String t(String s) => TranslationCache.translate(s, lang);
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

  // Build quick edit submenu (shows username for each proxy)
  final editItems = proxies
      .where((p) => p.type != 'direct')
      .map((p) => MenuItem(
            key: 'proxy_edit_${p.id}',
            label: p.name,
          ))
      .toList();

  final items = <MenuItem>[
    MenuItem(
      key: 'lux',
      label: version == 'unknown' ? 'Lux' : 'Lux $version',
      disabled: true,
    ),
    MenuItem.separator(),
    MenuItem(
      key: isConnected ? 'disconnect' : 'connect',
      label: isConnected ? t('Disconnect') : t('Connect'),
    ),
    MenuItem.separator(),
  ];

  // Proxy switcher
  if (proxyItems.isNotEmpty) {
    items.add(MenuItem.submenu(
      label: t('Switch Profile'),
      submenu: Menu(items: proxyItems),
    ));
  }

  // Quick edit
  if (editItems.isNotEmpty) {
    items.add(MenuItem.submenu(
      label: t('Edit Credentials'),
      submenu: Menu(items: editItems),
    ));
  }

  items.addAll([
    MenuItem.separator(),
    MenuItem(key: 'open_dashboard', label: tr().trayDashboardLabel),
    MenuItem(key: 'check_updates', label: t('Check for Updates…')),
    MenuItem.separator(),
    MenuItem(key: 'exit_app', label: tr().exit),
  ]);

  await trayManager.setContextMenu(Menu(items: items));
  await trayManager.setToolTip(
    isConnected ? 'Lux — ${t('Connected')}' : 'Lux — ${t('Disconnected')}',
  );
}
