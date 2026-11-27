import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lux/core/core_config.dart'
    show shouldSkipUpdateCheck, writeLastUpdateCheckAt, writePendingUpdateVersion;
import 'package:lux/model/app.dart';
import 'package:lux/pages/connections_page.dart';
import 'package:lux/pages/log_page.dart';
import 'package:lux/pages/proxies_page.dart';
import 'package:lux/pages/rules_page.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/notifier.dart';
import 'package:lux/util/updater.dart' show checkForUpdate, showUpdateDialog;
import 'package:lux/util/window_surface.dart';
import 'package:lux/widget/app_header_bar.dart';
import 'package:lux/widget/app_sidebar.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/windows_service_banner.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/core_manager.dart';

class Dashboard extends StatefulWidget {
  final String baseUrl;
  final String urlStr;
  final String homeDir;
  final CoreManager coreManager;

  const Dashboard(this.homeDir, this.baseUrl, this.urlStr, this.coreManager,
      {super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WindowListener {
  String curProxyInfo = "";
  int _selectedTab = 0;
  String? _settingsInitialFilter;

  static const _tabs = [
    AppSidebarTab(glyph: LuxGlyph.proxies, label: 'Proxies'),
    AppSidebarTab(glyph: LuxGlyph.rules, label: 'Rules'),
    AppSidebarTab(glyph: LuxGlyph.connections, label: 'Connections'),
    AppSidebarTab(glyph: LuxGlyph.logs, label: 'Log'),
    AppSidebarTab(glyph: LuxGlyph.settings, label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _runUpdateCheck();
  }

  /// Checks for updates at most once every 24 hours.
  /// Skips silently if checked recently to avoid nagging users after every launch.
  Future<void> _runUpdateCheck() async {
    await Future.delayed(const Duration(seconds: 15));
    if (!mounted) return;

    if (await shouldSkipUpdateCheck(minHours: 24)) return;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final info = await checkForUpdate();
        await writeLastUpdateCheckAt();
        if (info == null || !info.hasUpdate) return;
        if (!mounted) return;
        await writePendingUpdateVersion(info.latestVersion);
        if (!mounted) return;
        unawaited(notifier.show(
            'Lux ${info.latestVersion} is available. Open Lux to update.'));
        await showUpdateDialog(context, info);
        return;
      } catch (_) {
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 10 * (attempt + 1)));
        }
      }
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (Platform.isMacOS) {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
        await Future.delayed(const Duration(seconds: 1));
      }
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
    } else {
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
    }
  }

  void onCurProxyInfoChange(String info) {
    setState(() => curProxyInfo = info);
  }

  void _selectTab(int index, {String? settingsFilter}) {
    setState(() {
      _selectedTab = index;
      if (index == 4) {
        _settingsInitialFilter = settingsFilter;
      } else {
        _settingsInitialFilter = null;
      }
    });
  }

  Widget _buildPage() {
    switch (_selectedTab) {
      case 0:
        return ProxiesPage(
          coreManager: widget.coreManager,
          curProxyInfo: curProxyInfo,
          onCurProxyInfoChange: onCurProxyInfoChange,
          dashboardUrl: widget.urlStr,
        );
      case 1:
        return RulesPage(
          coreManager: widget.coreManager,
          onOpenBypassCidrs: () => _selectTab(4, settingsFilter: 'tun'),
        );
      case 2:
        return ConnectionsPage(coreManager: widget.coreManager);
      case 3:
        return LogPage(coreManager: widget.coreManager);
      case 4:
        return SettingsPage(
          coreManager: widget.coreManager,
          dashboardUrl: widget.urlStr,
          initialCategory: _settingsInitialFilter,
        );
      default:
        return const SizedBox();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final tier =
        context.select<AppStateModel, WindowSurfaceTier>((m) => m.surfaceTier);
    final isMac = Platform.isMacOS;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(LogicalKeyboardKey.comma, meta: isMac, control: !isMac):
            () => _selectTab(4),
        SingleActivator(LogicalKeyboardKey.digit1, meta: isMac, control: !isMac):
            () => _selectTab(0),
        SingleActivator(LogicalKeyboardKey.digit2, meta: isMac, control: !isMac):
            () => _selectTab(1),
        SingleActivator(LogicalKeyboardKey.digit3, meta: isMac, control: !isMac):
            () => _selectTab(2),
        SingleActivator(LogicalKeyboardKey.digit4, meta: isMac, control: !isMac):
            () => _selectTab(3),
        SingleActivator(LogicalKeyboardKey.digit5, meta: isMac, control: !isMac):
            () => _selectTab(4),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor:
              tier.isTranslucent ? Colors.transparent : tokens.canvasOpaque,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final compactSidebar = constraints.maxWidth < 700;
              return Row(
                children: [
                  AppSidebar(
                    tabs: _tabs,
                    selectedIndex: _selectedTab,
                    onSelected: (i) => _selectTab(i),
                    coreManager: widget.coreManager,
                    compact: compactSidebar,
                  ),
                  Expanded(
                    child: Container(
                      color: tokens.canvasFor(tier),
                      child: Column(
                        children: [
                          DragToMoveArea(
                            child: AppHeaderBar(
                              coreManager: widget.coreManager,
                              urlStr: widget.urlStr,
                              curProxyInfo: curProxyInfo,
                              onCurProxyInfoChange: onCurProxyInfoChange,
                            ),
                          ),
                          WindowsServiceBanner(coreManager: widget.coreManager),
                          Expanded(child: _buildPage()),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
