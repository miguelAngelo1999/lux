import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/model/app.dart';
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
      // Update intent before calling start/stop so the watchdog in home.dart
      // knows whether to restart.
      final appState = Provider.of<AppStateModel>(context, listen: false);
      appState.userWantsRunning = value;
      // Safety timeout: start() can retry ~15s x3 (~45s) and a wedged UAC
      // dialog or unresponsive core could hang longer. Cap the awaited op so
      // the spinner can never stick on forever and leave the toggle disabled.
      if (value) {
        await widget.coreManager.start().timeout(const Duration(seconds: 60));
        // Proxy env vars (HTTP_PROXY / NODE_EXTRA_CA_CERTS for Node/Electron
        // tools) are set centrally in CoreManager.start() — every start path
        // (toggle, tray, auto-connect, watchdog, wake) gets them.
      } else {
        await widget.coreManager.stop().timeout(const Duration(seconds: 30));
        // Env vars cleared centrally in CoreManager.stop().
      }
    } catch (e) {
      appLog('CORE', 'toggle ${value ? "start" : "stop"} failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: TText(value
              ? 'Could not connect. Check your proxy and try again.'
              : 'Could not disconnect cleanly.')),
        );
      }
    } finally {
      // Re-sync the switch position from the core's REAL state rather than
      // assuming the op succeeded — a failed/timed-out start must not leave
      // the toggle showing "on". Always clear the loading flag so the spinner
      // and the disabled state can never wedge.
      bool real = value;
      try {
        real = await widget.coreManager.getIsStarted();
      } catch (_) {}
      if (mounted) {
        setState(() {
          isStarted = real;
          isLoadingSwitch = false;
        });
        Provider.of<AppStateModel>(context, listen: false)
            .updateIsStarted(real);
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
    final isSwitchDisabled = isLoadingSwitch || widget.curProxyInfo.isEmpty;
    return AppBar(
        // dashboard.dart wraps this in a 50px PreferredSize; without
        // matching it here the default 56px gets squeezed and overlaps.
        toolbarHeight: 50,
        // On macOS with hidden title bar, leave space for the traffic lights.
        leadingWidth: Platform.isMacOS ? 80 : null,
        leading: Padding(
          padding: EdgeInsets.only(left: Platform.isMacOS ? 70 : 0),
          child: IconButton(
              tooltip: tl(context, 'Open web dashboard (advanced)'),
              onPressed: openWebDashboard,
              icon: const Icon(Icons.open_in_browser, size: 18)),
        ),
        title: Row(
          children: [
            ModeFanButton(
              modes: ruleList.rules,
              selected: ruleList.selectedId,
              labelOf: getRuleLabel,
              descriptionOf: getRuleDescription,
              iconOf: getRuleIcon,
              enabled: !isLoadingRuleDropdown,
              onSelected: (id) => handleSelectRule(id),
            ),
            SizedBox(width: 4),
            IconButton(
                tooltip: tr().addProxyTip,
                onPressed: _handleAdd,
                icon: const Icon(
                  Icons.add,
                )),
            Spacer(),
            Text(
              widget.curProxyInfo,
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 32,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  FittedBox(
                    child: Switch(
                      value: isStarted,
                      // Non-clickable while a connect/disconnect is in flight
                      // (isLoadingSwitch) or no proxy is selected.
                      onChanged: isSwitchDisabled ? null : onSwitchChanged,
                    ),
                  ),
                  // Progress spinner while connecting/disconnecting, so the
                  // user sees it IS working and doesn't spam-click. An opaque
                  // barrier over the switch also swallows taps during the op.
                  if (isLoadingSwitch)
                    Positioned.fill(
                      child: AbsorbPointer(
                        child: Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0.55),
                          alignment: Alignment.center,
                          child: const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: Platform.isWindows ? _windowsCaptionButtons() : null);
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
