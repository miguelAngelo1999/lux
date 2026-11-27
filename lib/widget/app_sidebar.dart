import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/error.dart';
import 'package:lux/model/app.dart';
import 'package:lux/theme.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/updater.dart'
    show
        UpdateInfo,
        UpdateState,
        checkForUpdate,
        showUpdateConfirmDialog,
        showUpdateProgressDialog,
        startUpdate,
        updateStateNotifier;
import 'package:lux/util/window_surface.dart';
import 'package:lux/widget/app_bottom_bar.dart' show TrafficState, getModeLabel;
import 'package:lux/widget/lux_icons.dart';
import 'package:provider/provider.dart';
import 'package:version/version.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

class AppSidebarTab {
  final LuxGlyph glyph;
  final String label;

  const AppSidebarTab({required this.glyph, required this.label});
}

/// Full-height translucent macOS Liquid Glass / Porcelain / Obsidian sidebar
/// with navigation destinations, interactive proxy-mode + traffic capsule,
/// and 1-click footer utilities (Check for Updates, Theme, Privacy Eye).
class AppSidebar extends StatefulWidget {
  final List<AppSidebarTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final CoreManager coreManager;
  final bool compact;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;

  const AppSidebar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.coreManager,
    this.compact = false,
    this.messengerKey,
  });

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> with WindowListener {
  Setting? _setting;
  ProxyMode _proxyMode = ProxyMode.tun;
  bool _sensitiveInfo = false;
  bool _savingSetting = false;
  TrafficState? _trafficData;
  WebSocketChannel? _trafficChannel;
  StreamSubscription? _trafficSub;
  bool _isWindowHidden = false;
  int? _hoveredIndex;
  double? _lastSyncedWidth;

  // Quick update state in the sidebar footer.
  String _appVersion = '';
  String _pendingUpdateVersion = '';
  bool _checkingUpdate = false;
  UpdateInfo? _cachedUpdateInfo;

  Future<void> _refreshSettingsAndVersion() async {
    try {
      final value = await widget.coreManager.getSetting();
      if (mounted) {
        setState(() {
          _setting = value;
          _proxyMode = value.mode;
          _sensitiveInfo = value.sensitiveInfoMode ?? false;
        });
      }
    } catch (_) {}

    try {
      final rawVersion = await getAppVersionString();
      var pending = await readPendingUpdateVersion();
      if (pending != null &&
          pending.isNotEmpty &&
          !_isNewer(pending, rawVersion)) {
        await writePendingUpdateVersion(null);
        pending = null;
      }
      if (mounted) {
        setState(() {
          _appVersion = rawVersion;
          _pendingUpdateVersion = pending ?? '';
        });
      }
    } catch (_) {}
  }

  bool _isNewer(String candidate, String current) {
    try {
      return Version.parse(candidate).compareTo(Version.parse(current)) > 0;
    } catch (_) {
      return candidate != current;
    }
  }

  void _onCoreGenerationChanged() {
    if (!mounted) return;
    _refreshSettingsAndVersion();
    if (_trafficChannel == null) {
      _connectTrafficChannel();
    }
  }

  void _connectTrafficChannel() {
    _trafficSub?.cancel();
    _trafficSub = null;
    widget.coreManager.getTrafficChannel().then((channel) async {
      if (channel == null || !mounted) return;
      try {
        await channel.ready;
      } catch (_) {
        _trafficChannel = null;
        widget.coreManager.clearTrafficChannel();
        return;
      }
      if (!mounted) return;
      _trafficChannel = channel;
      _trafficSub = _trafficChannel?.stream.listen(
        (message) {
          if (_isWindowHidden || !mounted) return;
          try {
            final value = TrafficData.fromJson(json.decode(message));
            setState(() => _trafficData = TrafficState(rawData: value));
          } catch (_) {}
        },
        onError: (_) {
          _trafficSub = null;
          _trafficChannel = null;
          widget.coreManager.clearTrafficChannel();
        },
        onDone: () {
          _trafficSub = null;
          _trafficChannel = null;
          widget.coreManager.clearTrafficChannel();
        },
        cancelOnError: true,
      );
    }).catchError((_) {
      _trafficChannel = null;
      widget.coreManager.clearTrafficChannel();
    });
  }

  void _showToast(SnackBar snackBar) {
    final messenger =
        widget.messengerKey?.currentState ?? ScaffoldMessenger.maybeOf(context);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(snackBar);
  }

  Future<void> _switchProxyMode(ProxyMode nextMode) async {
    if (_savingSetting || nextMode == _proxyMode) return;
    setState(() => _savingSetting = true);
    try {
      final current = _setting ?? await widget.coreManager.getSetting();
      final updated = current.copyWith(mode: nextMode);
      await widget.coreManager.saveSetting(updated);
      if (mounted) {
        setState(() {
          _setting = updated;
          _proxyMode = nextMode;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e is CoreElevationCancelledError
          ? tl(context, e.message)
          : 'Could not switch mode: $e';
      _showToast(SnackBar(content: Text(msg), backgroundColor: Colors.red));
      await _refreshSettingsAndVersion();
    } finally {
      if (mounted) setState(() => _savingSetting = false);
    }
  }

  Future<void> _toggleSensitiveInfo() async {
    if (_savingSetting) return;
    setState(() => _savingSetting = true);
    try {
      final current = _setting ?? await widget.coreManager.getSetting();
      final next = !(current.sensitiveInfoMode ?? false);
      final updated = current.copyWith(sensitiveInfoMode: next);
      await widget.coreManager.saveSetting(updated);
      if (!mounted) return;
      setState(() {
        _setting = updated;
        _sensitiveInfo = next;
      });
      _showToast(
        SnackBar(
          content: Text(next
              ? tl(context, 'Sensitive Info Mode enabled')
              : tl(context, 'Sensitive Info Mode disabled')),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (mounted) {
        _showToast(
          SnackBar(
              content: Text('Could not save: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _savingSetting = false);
    }
  }

  Future<void> _toggleTheme(BuildContext context) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final next = isDark ? ThemeMode.light : ThemeMode.dark;
    await writeTheme(next);
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    Provider.of<AppStateModel>(context, listen: false).updateTheme(next);
  }

  Future<void> _handleUpdatePillTap(UpdateState updateState) async {
    if (_checkingUpdate) return;
    if (updateState.isDownloading && updateState.updateInfo != null) {
      await showUpdateProgressDialog(context, updateState.updateInfo!);
      return;
    }

    final hasPending = _pendingUpdateVersion.isNotEmpty ||
        (updateState.updateInfo?.hasUpdate ?? false);

    if (hasPending) {
      UpdateInfo? info = _cachedUpdateInfo ?? updateState.updateInfo;
      if (info == null || !info.hasUpdate) {
        setState(() => _checkingUpdate = true);
        try {
          info = await checkForUpdate();
          _cachedUpdateInfo = info;
        } finally {
          if (mounted) setState(() => _checkingUpdate = false);
        }
      }
      if (!mounted) return;
      if (info != null && info.hasUpdate) {
        await writePendingUpdateVersion(info.latestVersion);
        if (mounted) {
          setState(() => _pendingUpdateVersion = info!.latestVersion);
          await startUpdate(context, info, showDialog: true);
        }
        return;
      }
      await writePendingUpdateVersion(null);
      if (mounted) {
        setState(() => _pendingUpdateVersion = '');
        _showToast(
          SnackBar(
            content: Text(tl(context, 'You are up to date')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Idle state: run an immediate 1-click update check.
    final upToDateMsg = tl(context, 'You are up to date');
    setState(() => _checkingUpdate = true);
    try {
      final info = await checkForUpdate();
      _cachedUpdateInfo = info;
      if (!mounted) return;
      if (info == null || !info.hasUpdate) {
        await writePendingUpdateVersion(null);
        if (!mounted) return;
        setState(() => _pendingUpdateVersion = '');
        _showToast(
          SnackBar(
            content: Text(upToDateMsg),
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        await writePendingUpdateVersion(info.latestVersion);
        if (!mounted) return;
        setState(() => _pendingUpdateVersion = info.latestVersion);
        await showUpdateConfirmDialog(context, info);
      }
    } catch (e) {
      if (mounted) {
        _showToast(
          SnackBar(
            content: Text('Update check failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _refreshSettingsAndVersion();
    windowManager.addListener(this);
    widget.coreManager.coreGeneration.addListener(_onCoreGenerationChanged);
    _connectTrafficChannel();
  }

  @override
  void onWindowFocus() {
    _isWindowHidden = false;
    _refreshSettingsAndVersion();
    if (_trafficChannel == null) {
      _connectTrafficChannel();
    }
  }

  @override
  void onWindowClose() {
    _isWindowHidden = true;
  }

  @override
  void dispose() {
    widget.coreManager.coreGeneration.removeListener(_onCoreGenerationChanged);
    windowManager.removeListener(this);
    _trafficSub?.cancel();
    _trafficChannel?.sink.close();
    super.dispose();
  }

  void _syncNativeWidth(double width) {
    if (_lastSyncedWidth == width) return;
    _lastSyncedWidth = width;
    WindowSurfaceBridge.syncSidebarWidth(width);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final tier =
        context.select<AppStateModel, WindowSurfaceTier>((m) => m.surfaceTier);
    final isStarted =
        context.select<AppStateModel, bool>((m) => m.isStarted);
    final isLiquidGlass = tier == WindowSurfaceTier.liquidGlass;
    final sidebarWidth = widget.compact
        ? 156.0
        : (isLiquidGlass ? 180.0 : 176.0);
    _syncNativeWidth(sidebarWidth);

    final innerContent = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top drag handle + authentic Lux logo (clear breathing room below
        // unified macOS traffic lights positioned at y=19..33).
        DragToMoveArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              13,
              Platform.isMacOS ? (isLiquidGlass ? 40 : 46) : 16,
              13,
              12,
            ),
            child: Row(
              children: [
                const LuxLogoMark(size: 19),
                const SizedBox(width: 8),
                Text(
                  'Lux',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                    color: tokens.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Navigation items
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < widget.tabs.length; i++)
                  _buildNavItem(context, tokens, i, widget.tabs[i]),
              ],
            ),
          ),
        ),
        // Bottom live interactive telemetry & mode capsule
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: _buildTelemetryCapsule(context, tokens, isStarted),
        ),
        // 1-click footer utility bar: Check for Updates + Theme + Privacy eye
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: _buildFooterUtilities(context, tokens),
        ),
      ],
    );

    if (isLiquidGlass) {
      // Sits directly over the native inset NSGlassEffectView (8px margin,
      // 16px corner radius) so real macOS Liquid Glass refracts cleanly.
      return SizedBox(
        key: const Key('app-sidebar'),
        width: sidebarWidth,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.sidebarTranslucent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: tokens.specularRim, width: 0.75),
            ),
            child: innerContent,
          ),
        ),
      );
    }

    return Container(
      key: const Key('app-sidebar'),
      width: sidebarWidth,
      decoration: BoxDecoration(
        color: tokens.sidebarFor(tier),
        border: Border(right: BorderSide(color: tokens.hairline, width: 1)),
      ),
      child: innerContent,
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    LuxTokens tokens,
    int index,
    AppSidebarTab tab,
  ) {
    final selected = index == widget.selectedIndex;
    final hovered = index == _hoveredIndex;

    final Color bg;
    if (selected) {
      bg = tokens.activeNavBg;
    } else if (hovered) {
      bg = tokens.subtlePillBg;
    } else {
      bg = Colors.transparent;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: selected,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoveredIndex = index),
          onExit: (_) {
            if (_hoveredIndex == index) setState(() => _hoveredIndex = null);
          },
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: Key('sidebar-tab-${tab.label.toLowerCase()}'),
              borderRadius: BorderRadius.circular(8),
              hoverColor: Colors.transparent,
              splashColor: tokens.cobalt.withValues(alpha: 0.08),
              highlightColor: tokens.subtlePillBg,
              onTap: () => widget.onSelected(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        selected ? tokens.activeNavBorder : Colors.transparent,
                    width: 0.75,
                  ),
                ),
                child: Row(
                  children: [
                    LuxIcon(
                      tab.glyph,
                      size: 15,
                      strokeWidth: 1.35,
                      color: selected ? tokens.cobalt : tokens.textSecondary,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: TText(
                        tab.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              selected ? FontWeight.w500 : FontWeight.w400,
                          color: selected
                              ? tokens.textPrimary
                              : tokens.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _modeDescription(ProxyMode mode) {
    switch (mode) {
      case ProxyMode.system:
        return tl(context, 'Browser & system-proxy apps');
      case ProxyMode.mixed:
        return tl(context, 'System proxy + TUN (recommended)');
      case ProxyMode.tun:
        return tl(context, 'Full-device virtual tunnel');
    }
  }

  Widget _buildTelemetryCapsule(
    BuildContext context,
    LuxTokens tokens,
    bool isStarted,
  ) {
    final modeLabel = getModeLabel(_proxyMode);
    final up =
        _trafficData?.upload != null ? '${_trafficData!.upload}/s' : '0 B/s';
    final down = _trafficData?.download != null
        ? '${_trafficData!.download}/s'
        : '0 B/s';
    final total = _trafficData?.total ?? '0 B';

    return Container(
      key: const Key('sidebar-telemetry'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.cardBg.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.hairline, width: 0.75),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1-click interactive Proxy Mode switcher right inside the capsule.
          Tooltip(
            message: tr().proxyModeTooltip,
            child: PopupMenuButton<ProxyMode>(
              key: const Key('sidebar-mode-switcher'),
              tooltip: '',
              enabled: !_savingSetting,
              padding: EdgeInsets.zero,
              onSelected: _switchProxyMode,
              itemBuilder: (ctx) => [
                for (final mode in const [
                  ProxyMode.mixed,
                  ProxyMode.system,
                  ProxyMode.tun,
                ])
                  PopupMenuItem<ProxyMode>(
                    value: mode,
                    height: 44,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 14,
                          child: mode == _proxyMode
                              ? LuxIcon(LuxGlyph.check,
                                  size: 12.5, color: tokens.cobalt)
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                getModeLabel(mode),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: mode == _proxyMode
                                      ? FontWeight.w500
                                      : FontWeight.w400,
                                  color: tokens.textPrimary,
                                ),
                              ),
                              Text(
                                _modeDescription(mode),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: tokens.textMuted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isStarted ? tokens.emerald : tokens.textMuted,
                        boxShadow: isStarted
                            ? [
                                BoxShadow(
                                  color: tokens.emerald.withValues(alpha: 0.45),
                                  blurRadius: 5,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        modeLabel,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: tokens.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_savingSetting)
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.4,
                          color: tokens.cobalt,
                        ),
                      )
                    else
                      LuxIcon(
                        LuxGlyph.chevronDown,
                        size: 11,
                        color: tokens.textMuted,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Tooltip(
            message: _trafficData?.uploadMsg ?? tr().bottomBarTip,
            child: Row(
              children: [
                LuxIcon(LuxGlyph.arrowUp, size: 11, color: tokens.textMuted),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    up,
                    style: luxMonoStyle(
                      fontSize: 10.5,
                      color: tokens.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Tooltip(
            message: _trafficData?.downloadMsg ?? tr().bottomBarTip,
            child: Row(
              children: [
                LuxIcon(LuxGlyph.arrowDown, size: 11, color: tokens.textMuted),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    down,
                    style: luxMonoStyle(
                      fontSize: 10.5,
                      color: tokens.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Container(height: 0.75, color: tokens.hairline),
          const SizedBox(height: 4),
          Tooltip(
            message: _trafficData?.totalMsg ?? tr().bottomBarTip,
            child: Text(
              total,
              style: luxMonoStyle(fontSize: 10, color: tokens.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooterUtilities(BuildContext context, LuxTokens tokens) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        // 1-click Version / Update pill
        Expanded(
          child: ValueListenableBuilder<UpdateState>(
            valueListenable: updateStateNotifier,
            builder: (context, updateState, _) {
              final isDownloading = updateState.isDownloading;
              final hasPending = _pendingUpdateVersion.isNotEmpty ||
                  (updateState.updateInfo?.hasUpdate ?? false);
              final targetVer = _pendingUpdateVersion.isNotEmpty
                  ? _pendingUpdateVersion
                  : (updateState.updateInfo?.latestVersion ?? '');
              final pct = updateState.progress != null
                  ? (updateState.progress! * 100).round()
                  : null;

              final highlight = isDownloading || hasPending;
              final String label;
              if (isDownloading) {
                label = pct != null ? '$pct%' : tl(context, 'Updating...');
              } else if (hasPending) {
                label = '↑ $targetVer';
              } else if (_appVersion.isNotEmpty) {
                label = 'v$_appVersion';
              } else {
                label = tl(context, 'Updates');
              }

              return Tooltip(
                message: hasPending
                    ? '${tl(context, 'Update available')}: $targetVer'
                    : tl(context, 'Check for Updates'),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: const Key('sidebar-update-pill'),
                    borderRadius: BorderRadius.circular(7),
                    onTap: () => _handleUpdatePillTap(updateState),
                    child: Container(
                      height: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      decoration: BoxDecoration(
                        color: highlight
                            ? tokens.amber.withValues(alpha: 0.14)
                            : tokens.subtlePillBg,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: highlight
                              ? tokens.amber.withValues(alpha: 0.45)
                              : tokens.hairline,
                          width: 0.75,
                        ),
                      ),
                      child: Row(
                        children: [
                          if (_checkingUpdate || isDownloading)
                            SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.4,
                                color: highlight ? tokens.amber : tokens.cobalt,
                              ),
                            )
                          else
                            LuxIcon(
                              highlight ? LuxGlyph.download : LuxGlyph.refresh,
                              size: 11,
                              color:
                                  highlight ? tokens.amber : tokens.textMuted,
                            ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              label,
                              style: luxMonoStyle(
                                fontSize: 10,
                                fontWeight: highlight
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                                color: highlight
                                    ? tokens.amber
                                    : tokens.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 4),
        // 1-click Theme toggle (Porcelain Light <-> Obsidian Dark)
        Tooltip(
          message: isDark
              ? tl(context, 'Switch to Light theme')
              : tl(context, 'Switch to Dark theme'),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const Key('sidebar-theme-toggle'),
              borderRadius: BorderRadius.circular(7),
              onTap: () => _toggleTheme(context),
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: tokens.subtlePillBg,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: tokens.hairline, width: 0.75),
                ),
                child: Center(
                  child: LuxIcon(
                    isDark ? LuxGlyph.sun : LuxGlyph.moon,
                    size: 12.5,
                    color: tokens.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // 1-click Sensitive Info Mode toggle (privacy eye)
        Tooltip(
          message: tl(context, 'Sensitive Info Mode'),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const Key('sidebar-privacy-toggle'),
              borderRadius: BorderRadius.circular(7),
              onTap: _toggleSensitiveInfo,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _sensitiveInfo
                      ? tokens.cobalt.withValues(alpha: 0.14)
                      : tokens.subtlePillBg,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: _sensitiveInfo
                        ? tokens.cobalt.withValues(alpha: 0.45)
                        : tokens.hairline,
                    width: 0.75,
                  ),
                ),
                child: Center(
                  child: LuxIcon(
                    _sensitiveInfo ? LuxGlyph.eyeOff : LuxGlyph.eye,
                    size: 12.5,
                    color: _sensitiveInfo ? tokens.cobalt : tokens.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
