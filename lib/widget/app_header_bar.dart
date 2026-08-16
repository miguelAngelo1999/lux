import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/model/app.dart';
import 'package:lux/widget/proxy_edit_dialog.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

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
    final value = await widget.coreManager.getIsStarted();
    setState(() {
      isStarted = value;
    });
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
      if (value) {
        await widget.coreManager.start();
        setState(() {
          isStarted = true;
        });
      } else {
        await widget.coreManager.stop();
        setState(() {
          isStarted = false;
        });
      }
    } finally {
      setState(() {
        isLoadingSwitch = false;
      });
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
      default:
        return name;
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    runtimeStatusChannel?.sink.close();
    super.dispose();
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

    if (runtimeStatusChannel == null) {
      widget.coreManager.getRuntimeStatusChannel().then((channel) async {
        if (channel == null) return;
        // Required by web_socket_channel 3.x. Missing it means the connect
        // toggle can stop reflecting the core's real state, because the status
        // frames never arrive and no error is raised.
        await channel.ready;
        if (!mounted) return;
        runtimeStatusChannel = channel;
        runtimeStatusChannel?.stream.listen((message) {
          RuntimeStatus value = RuntimeStatus.fromJson(json.decode(message));
          setState(() {
            if (!isLoadingSwitch) {
              isStarted = value.isStarted;
              Provider.of<AppStateModel>(context, listen: false)
                  .updateIsStarted(value.isStarted);
            }
          });
        });
      });
    }
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
        onSaved: () => refreshData(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DropdownMenuEntry<String>> menuEntries =
        UnmodifiableListView<DropdownMenuEntry<String>>(
      ruleList.rules.map<DropdownMenuEntry<String>>((String name) {
        String label = getRuleLabel(name);
        return DropdownMenuEntry(value: name, label: label);
      }),
    );
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
              tooltip: 'Open web dashboard (advanced)',
              onPressed: openWebDashboard,
              icon: const Icon(Icons.open_in_browser, size: 18)),
        ),
        title: Row(
          children: [
            SizedBox(
              height: 32,
              child: FittedBox(
                child: DropdownMenu<String>(
                  width: 184,
                  initialSelection: ruleList.selectedId,
                  onSelected: isLoadingRuleDropdown ? null : handleSelectRule,
                  dropdownMenuEntries: menuEntries,
                  textStyle: TextStyle(fontSize: 20),
                ),
              ),
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
              child: FittedBox(
                child: Switch(
                  value: isStarted,
                  onChanged: isSwitchDisabled ? null : onSwitchChanged,
                ),
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
