import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/pages/connections_page.dart';
import 'package:lux/pages/log_page.dart';
import 'package:lux/pages/proxies_page.dart';
import 'package:lux/pages/rules_page.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/util/updater.dart' show checkForUpdate, showUpdateDialog;
import 'package:lux/core/core_config.dart' show shouldSkipUpdateCheck, writeLastUpdateCheckAt;
import 'package:lux/widget/app_bottom_bar.dart';
import 'package:lux/widget/app_header_bar.dart';
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

  final _tabs = [
    (icon: Icons.swap_horiz, label: 'Proxies'),
    (icon: Icons.rule, label: 'Rules'),
    (icon: Icons.device_hub, label: 'Connections'),
    (icon: Icons.article_outlined, label: 'Log'),
    (icon: Icons.settings_outlined, label: 'Settings'),
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

    // Skip if checked within the last 24 hours
    if (await shouldSkipUpdateCheck(minHours: 24)) return;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final info = await checkForUpdate();
        // Record the check time regardless of outcome so we don't hammer the server
        await writeLastUpdateCheckAt();
        if (info == null || !info.hasUpdate) return;
        if (!mounted) return;
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
        return RulesPage(coreManager: widget.coreManager);
      case 2:
        return ConnectionsPage(coreManager: widget.coreManager);
      case 3:
        return LogPage(coreManager: widget.coreManager);
      case 4:
        return SettingsPage(coreManager: widget.coreManager);
      default:
        return const SizedBox();
    }
  }

  /// On Windows the hidden title bar leaves nothing to drag the window by,
  /// so the whole header doubles as the drag surface.
  Widget _wrapDraggable(Widget child) {
    if (!Platform.isWindows) return child;
    return DragToMoveArea(child: child);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(50),
        // Windows hides the native title bar, so the header itself has to
        // be the drag handle. Buttons inside still win the hit test.
        child: _wrapDraggable(AppHeaderBar(
          coreManager: widget.coreManager,
          urlStr: widget.urlStr,
          curProxyInfo: curProxyInfo,
          onCurProxyInfoChange: onCurProxyInfoChange,
        )),
      ),
      body: Row(
        children: [
          // Left navigation rail
          NavigationRail(
            selectedIndex: _selectedTab,
            onDestinationSelected: (i) => setState(() => _selectedTab = i),
            labelType: NavigationRailLabelType.all,
            minWidth: 64,
            destinations: _tabs
                .map((t) => NavigationRailDestination(
                      icon: Icon(t.icon, size: 20),
                      label: TText(t.label,
                          style: const TextStyle(fontSize: 10)),
                    ))
                .toList(),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          // Main content
          Expanded(child: _buildPage()),
        ],
      ),
      bottomNavigationBar: AppBottomBar(widget.coreManager),
    );
  }
}
