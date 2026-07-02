import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/pages/connections_page.dart';
import 'package:lux/pages/log_page.dart';
import 'package:lux/pages/proxies_page.dart';
import 'package:lux/pages/rules_page.dart';
import 'package:lux/pages/settings_page.dart';
import 'package:lux/util/updater.dart' show checkForUpdate, showUpdateDialog;
import 'package:lux/util/utils.dart' hide checkForUpdate;
import 'package:lux/widget/app_bottom_bar.dart';
import 'package:lux/widget/app_header_bar.dart';
import 'package:window_manager/window_manager.dart';

import 'core/core_manager.dart';
class Dashboard extends StatefulWidget {
  final String baseUrl;
  final String urlStr;
  final String homeDir;
  final CoreManager coreManager;
  final VoidCallback? onConnected;
  /// Called by external code (e.g. startup wizard) after adding a proxy,
  /// so the proxies page refreshes immediately.
  final void Function(VoidCallback trigger)? onRegisterProxyRefresh;

  const Dashboard(this.homeDir, this.baseUrl, this.urlStr, this.coreManager,
      {super.key, this.onConnected, this.onRegisterProxyRefresh});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WindowListener {
  String curProxyInfo = "";
  int _selectedTab = 0;
  // Callback set by ProxiesPage so the header bar can trigger a refresh after adding a proxy.
  VoidCallback? _refreshProxies;

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
    // Register refresh callback so external callers (e.g. startup wizard) can
    // trigger a proxy list refresh after adding a proxy.
    widget.onRegisterProxyRefresh?.call(() => _refreshProxies?.call());
  }

  Future<void> _runUpdateCheck() async {
    // Small delay so it doesn't race with startup
    await Future.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    final info = await checkForUpdate();
    if (info == null || !info.hasUpdate) return;
    if (!mounted) return;
    await showUpdateDialog(context, info);
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
          onRegisterRefresh: (cb) => _refreshProxies = cb,
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

  @override
  Widget build(BuildContext context) {
    // On Windows with hidden title bar, wrap in DragToMoveArea and pass
    // window control buttons as AppBar actions (no Stack overlap).
    final windowControls = Platform.isWindows
        ? <Widget>[_WindowControls()]
        : null;

    final headerBar = AppHeaderBar(
      coreManager: widget.coreManager,
      urlStr: widget.urlStr,
      curProxyInfo: curProxyInfo,
      onCurProxyInfoChange: onCurProxyInfoChange,
      onConnected: widget.onConnected,
      onProxyListChanged: () => _refreshProxies?.call(),
      extraActions: windowControls,
    );

    final appBar = PreferredSize(
      preferredSize: const Size.fromHeight(50),
      child: Platform.isWindows
          ? DragToMoveArea(child: headerBar)
          : headerBar,
    );

    return Scaffold(
      appBar: appBar,
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
                      label: Text(t.label,
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
/// the borderless window on Windows.
class _WindowControls extends StatefulWidget {
  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _isMaximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white70 : Colors.black54;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ControlBtn(
          icon: Icons.remove,
          fg: fg,
          tooltip: 'Minimize',
          onTap: () => windowManager.minimize(),
        ),
        _ControlBtn(
          icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
          fg: fg,
          tooltip: _isMaximized ? 'Restore' : 'Maximize',
          onTap: () => _isMaximized
              ? windowManager.unmaximize()
              : windowManager.maximize(),
        ),
        _ControlBtn(
          icon: Icons.close,
          fg: fg,
          tooltip: 'Close',
          hoverColor: Colors.red,
          onTap: () => windowManager.close(),
        ),
      ],
    );
  }
}

class _ControlBtn extends StatefulWidget {
  final IconData icon;
  final Color fg;
  final String tooltip;
  final Color? hoverColor;
  final VoidCallback onTap;

  const _ControlBtn({
    required this.icon,
    required this.fg,
    required this.tooltip,
    required this.onTap,
    this.hoverColor,
  });

  @override
  State<_ControlBtn> createState() => _ControlBtnState();
}

class _ControlBtnState extends State<_ControlBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hovered
        ? (widget.hoverColor ?? Colors.grey.withValues(alpha: 0.3))
        : Colors.transparent;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 46,
            height: 50,
            color: bg,
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered && widget.hoverColor != null
                  ? Colors.white
                  : widget.fg,
            ),
          ),
        ),
      ),
    );
  }
}
