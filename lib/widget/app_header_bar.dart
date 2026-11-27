import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/model/app.dart';
import 'package:lux/theme.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/proxy_edit_dialog.dart';
import 'package:lux/widget/mode_fan_button.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

import 'package:lux/util/t_text.dart';
import 'package:lux/util/app_log.dart';

import '../core/core_config.dart';
import '../core/core_manager.dart';
import '../error.dart';
import '../tr.dart';

class AppHeaderBar extends StatefulWidget {
  final CoreManager coreManager;
  final String curProxyInfo;
  final void Function(String) onCurProxyInfoChange;

  const AppHeaderBar(
      {super.key,
      required this.coreManager,
      required this.urlStr,
      required this.curProxyInfo,
      required this.onCurProxyInfoChange});

  final String urlStr;

  @override
  State<AppHeaderBar> createState() => _State();
}

class _State extends State<AppHeaderBar> with WindowListener {
  bool isStarted = false;
  RuleList ruleList = RuleList(<String>[], "");
  bool isLoadingSwitch = false;
  bool isLoadingRuleList = false;
  bool isLoadingRuleDropdown = false;
  WebSocketChannel? runtimeStatusChannel;
  StreamSubscription? _runtimeStatusSubscription;
  Timer? _statusPollTimer;

  /// Windows draws its own caption buttons because hiding the native title
  /// bar removes them, so the maximised state has to be tracked here.
  bool isMaximized = false;

  void openWebDashboard() {
    launchUrl(Uri.parse(widget.urlStr));
  }

  Future<void> refreshData() async {
    if (!isLoadingSwitch) {
      refreshIsStarted();
    }

    refreshCurProxyInfo();

    if (!isLoadingRuleDropdown) {
      refreshRuleList();
    }
  }

  Future<void> refreshIsStarted() async {
    try {
      final value = await widget.coreManager.getIsStarted();
      if (!mounted) return;
      if (!isLoadingSwitch) {
        setState(() {
          isStarted = value;
        });
        Provider.of<AppStateModel>(context, listen: false)
            .updateIsStarted(value);
      }
    } catch (_) {}
  }

  Future<void> refreshCurProxyInfo() async {
    final value = await widget.coreManager.getCurProxyInfo();
    setState(() {
      widget.onCurProxyInfoChange(value);
    });
  }

  Future<void> refreshRuleList() async {
    final value = await widget.coreManager.getRuleList();
    setState(() {
      ruleList = value;
    });
  }

  void onSwitchChanged(bool value) async {
    try {
      setState(() {
        isLoadingSwitch = true;
      });
      await widget.coreManager.toggleConnection(value);
    } catch (e) {
      appLog('CORE', 'toggle ${value ? "start" : "stop"} failed: $e');
      if (mounted) {
        final msg = e is CoreElevationCancelledError
            ? e.message
            : (value
                ? 'Could not connect. Check your proxy and try again.'
                : 'Could not disconnect cleanly.');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: TText(msg)),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isStarted = widget.coreManager.appState.isStarted;
          isLoadingSwitch = false;
        });
      }
    }
  }

  Future<void> handleSelectRule(String? id) async {
    if (id == null) {
      return;
    }
    try {
      setState(() {
        isLoadingRuleDropdown = true;
      });
      await widget.coreManager.selectRule(id);
      setState(() {
        ruleList.selectedId = id;
      });
    } finally {
      setState(() {
        isLoadingRuleDropdown = false;
      });
    }
  }

  String getRuleLabel(String name) {
    switch (name) {
      case "proxy_all":
        return tr().proxyAllRuleLabel;
      case "proxy_gfw":
        return tr().proxyGFWRuleLabel;
      case "bypass_cn":
        return tr().bypassCNRuleLabel;
      case "bypass_all":
        return tr().bypassAllRuleLabel;
      case "bypass_except_proxy":
        return tl(context, 'Bypass (keep proxy rules)');
      default:
        return name;
    }
  }

  // One-line description shown under each mode in the chooser so it's obvious
  // what each does without trial and error.
  String getRuleDescription(String name) {
    switch (name) {
      case "proxy_all":
        return tl(context, 'Everything through the proxy');
      case "proxy_gfw":
        return tl(context, 'Proxy blocked sites, rest direct');
      case "bypass_cn":
        return tl(context, 'Direct for local sites, proxy the rest');
      case "bypass_all":
        return tl(context, 'Everything direct (ads still blocked)');
      case "bypass_except_proxy":
        return tl(context, 'Direct, but your per-proxy rules still apply');
      default:
        return '';
    }
  }

  LuxGlyph getRuleGlyph(String name) {
    switch (name) {
      case "proxy_all":
        return LuxGlyph.shield;
      case "proxy_gfw":
        return LuxGlyph.globe;
      case "bypass_cn":
        return LuxGlyph.home;
      case "bypass_all":
        return LuxGlyph.bolt;
      case "bypass_except_proxy":
        return LuxGlyph.route;
      default:
        return LuxGlyph.rules;
    }
  }

  IconData getRuleIcon(String name) {
    switch (name) {
      case "proxy_all":
        return Icons.shield;
      case "proxy_gfw":
        return Icons.public;
      case "bypass_cn":
        return Icons.home_outlined;
      case "bypass_all":
        return Icons.flash_on;
      case "bypass_except_proxy":
        return Icons.alt_route;
      default:
        return Icons.rule;
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    _runtimeStatusSubscription?.cancel();
    _runtimeStatusSubscription = null;
    runtimeStatusChannel?.sink.close();
    super.dispose();
  }

  void _initRuntimeStatusChannel() {
    widget.coreManager.getRuntimeStatusChannel().then((channel) async {
      if (channel == null || !mounted) return;
      try {
        await channel.ready;
      } catch (e) {
        appLog('WS', 'runtime-status ready error: $e');
        widget.coreManager.clearRuntimeStatusChannel();
        return;
      }
      if (!mounted) return;
      runtimeStatusChannel = channel;
      _runtimeStatusSubscription?.cancel();
      _runtimeStatusSubscription = channel.stream.listen(
        (message) {
          try {
            RuntimeStatus value = RuntimeStatus.fromJson(json.decode(message));
            if (mounted && !isLoadingSwitch) {
              setState(() {
                isStarted = value.isStarted;
              });
              Provider.of<AppStateModel>(context, listen: false)
                  .updateIsStarted(value.isStarted);
            }
          } catch (e) {
            appLog('WS', 'runtime-status decode error: $e');
          }
        },
        onError: (e) {
          appLog('WS', 'runtime-status stream error: $e');
          _runtimeStatusSubscription?.cancel();
          _runtimeStatusSubscription = null;
          runtimeStatusChannel = null;
          widget.coreManager.clearRuntimeStatusChannel();
        },
        onDone: () {
          _runtimeStatusSubscription?.cancel();
          _runtimeStatusSubscription = null;
          runtimeStatusChannel = null;
          widget.coreManager.clearRuntimeStatusChannel();
        },
      );
    }).catchError((e) {
      appLog('WS', 'runtime-status connection failed: $e');
      widget.coreManager.clearRuntimeStatusChannel();
    });
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (Platform.isWindows) {
      windowManager.isMaximized().then((value) {
        if (mounted) setState(() => isMaximized = value);
      });
    }
    refreshData();
    _initRuntimeStatusChannel();

    // Periodic polling ensures toggle state stays in sync even if WebSocket
    // drops or on startup before auto-connect kicks in.
    _statusPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (!isLoadingSwitch) {
        refreshIsStarted();
        refreshCurProxyInfo();
      }
    });
  }

  @override
  void onWindowFocus() {
    refreshData();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => isMaximized = false);
  }

  void _handleAdd() async {
    await showDialog(
      context: context,
      builder: (context) => ProxyEditDialog(
        coreManager: widget.coreManager,
        onSaved: () {
          refreshData();
          // Notify the proxies page so a newly-added proxy shows immediately
          // without the user having to switch pages and back.
          if (mounted) {
            Provider.of<AppStateModel>(context, listen: false).bumpProxyList();
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final appStarted =
        context.select<AppStateModel, bool>((model) => model.isStarted);
    final switchValue =
        isLoadingSwitch ? isStarted : (isStarted || appStarted) && appStarted;
    final isSwitchDisabled = isLoadingSwitch || widget.curProxyInfo.isEmpty;

    return Container(
      height: 52,
      padding: EdgeInsets.only(
        left: 16,
        right: Platform.isWindows ? 4 : 16,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.hairline, width: 0.75)),
      ),
      child: Row(
        children: [
          ModeFanButton(
            modes: ruleList.rules,
            selected: ruleList.selectedId,
            labelOf: getRuleLabel,
            descriptionOf: getRuleDescription,
            iconOf: getRuleIcon,
            glyphOf: getRuleGlyph,
            enabled: !isLoadingRuleDropdown,
            onSelected: (id) => handleSelectRule(id),
          ),
          const Spacer(),
          // Quiet hairline "+ Add Proxy" capsule
          Tooltip(
            message: tr().addProxyTip,
            child: InkWell(
              key: const Key('header-add-proxy-button'),
              borderRadius: BorderRadius.circular(8),
              onTap: _handleAdd,
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: tokens.cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: tokens.hairlineStrong, width: 0.75),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LuxIcon(LuxGlyph.plus, size: 13, color: tokens.textSecondary),
                    const SizedBox(width: 6),
                    TText(
                      'Add Proxy',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: tokens.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: tl(context, 'Open web dashboard (advanced)'),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: openWebDashboard,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: tokens.cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: tokens.hairlineStrong, width: 0.75),
                ),
                child: Center(
                  child: LuxIcon(
                    LuxGlyph.externalLink,
                    size: 13.5,
                    color: tokens.textSecondary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(width: 0.75, height: 18, color: tokens.hairline),
          const SizedBox(width: 12),
          TText(
            switchValue ? 'Connected' : 'Disconnected',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: switchValue ? tokens.textPrimary : tokens.textMuted,
            ),
          ),
          const SizedBox(width: 8),
          _buildMasterToggle(tokens, switchValue, isSwitchDisabled),
          if (Platform.isWindows) ...[
            const SizedBox(width: 6),
            ..._windowsCaptionButtons(),
          ],
        ],
      ),
    );
  }

  Widget _buildMasterToggle(
    LuxTokens tokens,
    bool switchValue,
    bool disabled,
  ) {
    return SizedBox(
      width: 40,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          MouseRegion(
            cursor: disabled
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: GestureDetector(
              key: const Key('header-master-toggle'),
              onTap: disabled ? null : () => onSwitchChanged(!switchValue),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                width: 38,
                height: 21,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: switchValue
                      ? tokens.emerald
                      : tokens.subtlePillBg,
                  border: Border.all(
                    color: switchValue
                        ? tokens.emerald
                        : tokens.hairlineStrong,
                    width: 0.75,
                  ),
                  boxShadow: switchValue
                      ? [
                          BoxShadow(
                            color: tokens.emerald.withValues(alpha: 0.28),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  alignment: switchValue
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 15.5,
                    height: 15.5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.16),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (isLoadingSwitch)
            Positioned.fill(
              child: AbsorbPointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: tokens.cardBg.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: tokens.cobalt,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Minimise / maximise / close for Windows, replacing the buttons lost
  /// with the native title bar. Close goes through windowManager so the
  /// existing setPreventClose handling still runs.
  List<Widget> _windowsCaptionButtons() {
    final brightness = Theme.of(context).brightness;
    return [
      WindowCaptionButton.minimize(
        brightness: brightness,
        onPressed: () => windowManager.minimize(),
      ),
      if (isMaximized)
        WindowCaptionButton.unmaximize(
          brightness: brightness,
          onPressed: () => windowManager.unmaximize(),
        )
      else
        WindowCaptionButton.maximize(
          brightness: brightness,
          onPressed: () => windowManager.maximize(),
        ),
      WindowCaptionButton.close(
        brightness: brightness,
        onPressed: () => windowManager.close(),
      ),
    ];
  }
}
