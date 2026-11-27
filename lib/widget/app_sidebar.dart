import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/theme.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/window_surface.dart';
import 'package:lux/widget/app_bottom_bar.dart' show TrafficState, getModeLabel;
import 'package:lux/widget/lux_icons.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

class AppSidebarTab {
  final LuxGlyph glyph;
  final String label;

  const AppSidebarTab({required this.glyph, required this.label});
}

/// Option A full-height translucent macOS Liquid Glass / Porcelain / Obsidian
/// sidebar with navigation destinations and a live bottom telemetry capsule.
class AppSidebar extends StatefulWidget {
  final List<AppSidebarTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final CoreManager coreManager;

  const AppSidebar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.coreManager,
  });

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> with WindowListener {
  ProxyMode _proxyMode = ProxyMode.tun;
  TrafficState? _trafficData;
  WebSocketChannel? _trafficChannel;
  StreamSubscription? _trafficSub;
  bool _isWindowHidden = false;
  int? _hoveredIndex;

  Future<void> _refreshMode() async {
    try {
      final value = await widget.coreManager.getSetting();
      if (!mounted) return;
      setState(() => _proxyMode = value.mode);
    } catch (_) {}
  }

  void _onCoreGenerationChanged() {
    if (!mounted) return;
    _refreshMode();
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

  @override
  void initState() {
    super.initState();
    _refreshMode();
    windowManager.addListener(this);
    widget.coreManager.coreGeneration.addListener(_onCoreGenerationChanged);
    _connectTrafficChannel();
  }

  @override
  void onWindowFocus() {
    _isWindowHidden = false;
    _refreshMode();
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

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final tier =
        context.select<AppStateModel, WindowSurfaceTier>((m) => m.surfaceTier);
    final isStarted =
        context.select<AppStateModel, bool>((m) => m.isStarted);
    final isLiquidGlass = tier == WindowSurfaceTier.liquidGlass;

    final innerContent = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top drag handle + brand mark (leaves room for macOS traffic lights).
        DragToMoveArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              14,
              Platform.isMacOS ? (isLiquidGlass ? 36 : 42) : 16,
              14,
              14,
            ),
            child: Row(
              children: [
                LuxLogoMark(size: 16, color: tokens.cobalt),
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
        // Bottom live telemetry capsule
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: _buildTelemetryCapsule(context, tokens, isStarted),
        ),
      ],
    );

    if (isLiquidGlass) {
      // Sits directly over the native inset NSGlassEffectView (8px margin,
      // 164px wide, 14px radius) so real macOS Liquid Glass refracts cleanly.
      return SizedBox(
        key: const Key('app-sidebar'),
        width: 180,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.sidebarTranslucent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: tokens.specularRim, width: 0.75),
            ),
            child: innerContent,
          ),
        ),
      );
    }

    return Container(
      key: const Key('app-sidebar'),
      width: 176,
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
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hoveredIndex = index),
        onExit: (_) {
          if (_hoveredIndex == index) setState(() => _hoveredIndex = null);
        },
        child: GestureDetector(
          key: Key('sidebar-tab-${tab.label.toLowerCase()}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSelected(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? tokens.activeNavBorder : Colors.transparent,
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
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: selected ? tokens.textPrimary : tokens.textSecondary,
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
  }

  Widget _buildTelemetryCapsule(
    BuildContext context,
    LuxTokens tokens,
    bool isStarted,
  ) {
    final modeLabel = getModeLabel(_proxyMode);
    final up = _trafficData?.upload != null ? '${_trafficData!.upload}/s' : '0 B/s';
    final down =
        _trafficData?.download != null ? '${_trafficData!.download}/s' : '0 B/s';
    final total = _trafficData?.total ?? '0 B';

    return Container(
      key: const Key('sidebar-telemetry'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: tokens.cardBg.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.hairline, width: 0.75),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: tr().proxyModeTooltip,
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
              ],
            ),
          ),
          const SizedBox(height: 7),
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
          const SizedBox(height: 6),
          Container(height: 0.75, color: tokens.hairline),
          const SizedBox(height: 5),
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
}
