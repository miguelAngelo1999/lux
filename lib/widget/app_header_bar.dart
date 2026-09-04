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

import 'package:lux/util/t_text.dart';

import '../core/core_config.dart';
import '../core/core_manager.dart';
import '../tr.dart';
import '../util/utils.dart';

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
        // Set proxy env vars from the user's GUI session (not the root core).
        // launchctl setenv only works for the session it's called from.
        if (Platform.isMacOS) {
          _setProxyEnv();
        }
      } else {
        await widget.coreManager.stop();
        setState(() {
          isStarted = false;
        });
        if (Platform.isMacOS) {
          _clearProxyEnv();
        }
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
              tooltip: tl(context, 'Open web dashboard (advanced)'),
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


/// Sets proxy and Node.js env vars in the user's GUI session via launchctl.
/// Must run from the Flutter app (user context), NOT from lux_core (root).
///
/// NODE_EXTRA_CA_CERTS points to the PEM bundle that lux_core writes at
/// {homeDir}/proxy_ca_bundle.pem when it starts — a real text PEM file
/// exported from the System Keychain that Node.js can actually read.
/// The broken /Library/Keychains/System.keychain path (a binary file)
/// is intentionally not used here.
void _setProxyEnv() async {
  const proxy = 'http://127.0.0.1:1090';
  const noProxy = 'localhost,127.0.0.1,10.255.0.1,*.local';

  // Resolve the lux home dir to find the PEM bundle lux_core writes there.
  final homeDir = await getHomeDir();
  final caBundlePath = '$homeDir/proxy_ca_bundle.pem';

  final vars = {
    'HTTP_PROXY': proxy,
    'HTTPS_PROXY': proxy,
    'http_proxy': proxy,
    'https_proxy': proxy,
    'NO_PROXY': noProxy,
    'no_proxy': noProxy,
    'NODE_EXTRA_CA_CERTS': caBundlePath,
    // NODE_TLS_REJECT_UNAUTHORIZED and NODE_OPTIONS are intentionally omitted.
    // Setting them to 0 / --use-openssl-ca disables TLS verification globally,
    // which is worse than the original problem. The PEM bundle is the correct fix.
  };
  for (final e in vars.entries) {
    await Process.run('launchctl', ['setenv', e.key, e.value]);
  }
}

void _clearProxyEnv() async {
  final keys = [
    'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy',
    'NO_PROXY', 'no_proxy',
    'NODE_EXTRA_CA_CERTS',
    // Legacy: unset even if we stopped setting them
    'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_OPTIONS',
  ];
  for (final k in keys) {
    await Process.run('launchctl', ['unsetenv', k]);
  }
}
