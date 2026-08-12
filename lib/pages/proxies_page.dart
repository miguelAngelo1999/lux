import 'package:flutter/material.dart';
import 'package:lux/const/const.dart';
import 'package:lux/model/app.dart';
import 'package:lux/tr.dart';
import 'package:lux/widget/password_peek_dialog.dart';
import 'package:lux/widget/proxy_edit_dialog.dart';
import 'package:lux/widget/proxy_list_card.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../core/core_config.dart';
import '../core/core_manager.dart';

class ProxiesPage extends StatefulWidget {
  final CoreManager coreManager;
  final String curProxyInfo;
  final String dashboardUrl;
  final void Function(String) onCurProxyInfoChange;
  const ProxiesPage(
      {super.key,
      required this.coreManager,
      required this.curProxyInfo,
      required this.onCurProxyInfoChange,
      required this.dashboardUrl});

  @override
  State<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends State<ProxiesPage> with WindowListener {
  ProxyListGroup proxyListGroup = ProxyListGroup(
      allProxies: <ProxyItem>[],
      selectedId: "",
      subscriptions: <SubscriptionItem>[]);

  List<SubscriptionItem> subscriptionList = <SubscriptionItem>[];

  bool isLoadingProxyList = false;

  bool isLoadingProxyRadio = false;

  var isCollapsedMap = <String, bool>{};

  Future<void> refreshProxyList() async {
    final proxyList = await widget.coreManager.getProxyList();
    final subscriptionListValue =
        await widget.coreManager.getSubscriptionList();
    setState(() {
      subscriptionList = subscriptionListValue.value;
      proxyListGroup = ProxyListGroup(
          allProxies: proxyList.proxies,
          subscriptions: subscriptionList,
          selectedId: proxyList.id);

      Provider.of<AppStateModel>(context, listen: false)
          .updateSelectedProxyId(proxyListGroup.selectedId);
      for (var group in proxyListGroup.groups) {
        var key = group.id;
        if (!isCollapsedMap.containsKey(key)) {
          setState(() {
            isCollapsedMap[key] = true;
          });
        }
      }
    });
  }

  Future<void> refreshData() async {
    if (!isLoadingProxyRadio) {
      refreshProxyList();
    }
  }

  Future<void> handleSelectProxy(String? id) async {
    if (id == null) {
      return;
    }
    try {
      setState(() {
        isLoadingProxyRadio = true;
      });
      await widget.coreManager.selectProxy(id);
      setState(() {
        proxyListGroup.selectedId = id;
        Provider.of<AppStateModel>(context, listen: false)
            .updateSelectedProxyId(id);
        var curProxy = proxyListGroup.allProxies.firstWhere((p) => p.id == id);

        var newCurProxyInfo = curProxy.name.isNotEmpty
            ? curProxy.name
            : "${curProxy.server}:${curProxy.port}";
        widget.onCurProxyInfoChange(newCurProxyInfo);
      });
    } finally {
      setState(() {
        isLoadingProxyRadio = false;
      });
    }
  }

  @override
  void onWindowFocus() {
    refreshData();
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    refreshData();
  }

  @override
  void dispose() {
    super.dispose();
    windowManager.removeListener(this);
  }

  bool getIsCollapsed(ProxyList item) {
    return isCollapsedMap.containsKey(item.id)
        ? (isCollapsedMap[item.id] as bool)
        : true;
  }

  void handleCollapse(ProxyList item) {
    setState(() {
      isCollapsedMap[item.id] = !getIsCollapsed(item);
    });
  }

  void _handleDeleteItem(ProxyItem item) async {
    await widget.coreManager.deleteProxies([item.id]);
    await refreshData();
    if (item.id == proxyListGroup.selectedId) {
      widget.onCurProxyInfoChange("");
    }
  }

  void _handleEditItem(ProxyItem item) async {
    // Fetch full proxy detail for editing
    final detail = await widget.coreManager.getProxyDetail(item.id);
    if (!mounted || detail == null) return;

    await showDialog(
      context: context,
      builder: (context) => ProxyEditDialog(
        coreManager: widget.coreManager,
        initialValue: detail,
        onSaved: () => refreshData(),
      ),
    );
  }

  void _handleQrCode(ProxyItem item) async {
    final editingUrl = "${widget.dashboardUrl}&mode=qrCode&proxyId=${item.id}";
    launchUrl(Uri.parse(editingUrl));
  }

  void _handleItemChange(ProxyItemAction action, ProxyItem item) async {
    switch (action) {
      case ProxyItemAction.delete:
        _handleDeleteItem(item);
      case ProxyItemAction.edit:
        _handleEditItem(item);
      case ProxyItemAction.qrCode:
        _handleQrCode(item);
      case ProxyItemAction.peekPassword:
        _handlePeekPassword(item);
      case ProxyItemAction.lockPassword:
        _handleLockPassword(item);
    }
  }

  void _handlePeekPassword(ProxyItem item) async {
    await showPasswordPeekDialog(
      context: context,
      coreManager: widget.coreManager,
      proxyItem: item,
    );
  }

  void _handleLockPassword(ProxyItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr().lockPasswordConfirmTitle),
        content: Text(tr().lockPasswordConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr().lockPassword),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    try {
      await widget.coreManager.lockProxyPassword(item.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr().lockPasswordSuccess)),
      );
      // Refresh the proxy list to reflect the locked state
      refreshProxyList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to lock password: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toolbar with detect button
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              const Spacer(),
              _isDetecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton.icon(
                      onPressed: _detectProxies,
                      icon: const Icon(Icons.wifi_find, size: 16),
                      label: const Text('Detect Proxy',
                          style: TextStyle(fontSize: 12)),
                    ),
            ],
          ),
        ),
        Expanded(
          child: RadioGroup<String>(
            groupValue: proxyListGroup.selectedId,
            onChanged: handleSelectProxy,
            child: proxyListGroup.groups.isEmpty
                ? const Center(
                    child: Text('No proxies configured',
                        style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    itemCount: proxyListGroup.groups.length,
                    itemBuilder: (context, index) {
                      return ProxyListCard(
                        proxyList: proxyListGroup.groups[index],
                        key: Key(proxyListGroup.groups[index].id),
                        isCollapsed:
                            getIsCollapsed(proxyListGroup.groups[index]),
                        onCollapse: () =>
                            {handleCollapse(proxyListGroup.groups[index])},
                        onItemChange: _handleItemChange,
                        subscriptionList: subscriptionList,
                        coreManager: widget.coreManager,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  bool _isDetecting = false;

  Future<_ProxyCredentials?> _promptCredentials(DetectedProxy proxy) async {
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    String passwordMode = 'persistent';
    int ttlMinutes = 60;

    final result = await showDialog<_ProxyCredentials>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Credentials for ${proxy.host}:${proxy.port}'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: usernameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => Navigator.pop(
                    ctx,
                    _ProxyCredentials(
                      username: usernameCtrl.text,
                      password: passwordCtrl.text,
                      passwordMode: passwordMode,
                      ttlMinutes: ttlMinutes,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: passwordMode,
                  decoration: const InputDecoration(
                    labelText: 'Password type',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'persistent', child: Text('Persistent (saved)')),
                    DropdownMenuItem(value: 'timed', child: Text('Timed (expires)')),
                    DropdownMenuItem(value: 'one-time', child: Text('One-time (cleared after use)')),
                  ],
                  onChanged: (v) => setDialogState(() => passwordMode = v!),
                ),
                if (passwordMode == 'timed') ...[
                  const SizedBox(height: 12),
                  TextField(
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Expires after (minutes)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: '$ttlMinutes'),
                    onChanged: (v) => ttlMinutes = int.tryParse(v) ?? 60,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Leave empty if the proxy does not require authentication.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                _ProxyCredentials(
                  username: usernameCtrl.text,
                  password: passwordCtrl.text,
                  passwordMode: passwordMode,
                  ttlMinutes: ttlMinutes,
                ),
              ),
              child: const Text('Add Proxy'),
            ),
          ],
        ),
      ),
    );

    usernameCtrl.dispose();
    passwordCtrl.dispose();
    return result;
  }

  Future<void> _detectProxies() async {
    setState(() => _isDetecting = true);
    try {
      final result = await widget.coreManager.detectProxies();
      if (!mounted) return;

      if (result.proxies.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message.isNotEmpty
                ? result.message
                : 'No proxies detected on this network'),
          ),
        );
        return;
      }

      // Show detected proxies and offer to add them
      final added = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Detected Proxies'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result.pacUrl.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Found via PAC: ${result.pacUrl}',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ),
                ...result.proxies.map((p) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.dns, size: 20),
                      title: Text('${p.host}:${p.port}'),
                      subtitle: const Text('HTTP Proxy'),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Add ${result.proxies.length} Prox${result.proxies.length == 1 ? "y" : "ies"}'),
            ),
          ],
        ),
      );

      if (added == true) {
        // Step 2: Prompt for credentials and password type
        final creds = await _promptCredentials(result.proxies.first);
        if (creds == null) return;

        // Step 3: Add the proxy with credentials
        for (final p in result.proxies) {
          await widget.coreManager.addProxy({
            'name': p.host,
            'type': 'http',
            'server': p.host,
            'port': int.tryParse(p.port) ?? 8080,
            'pacUrl': p.pacUrl,
            if (creds.username.isNotEmpty) 'username': creds.username,
            if (creds.password.isNotEmpty) 'password': creds.password,
            if (creds.passwordMode.isNotEmpty) 'passwordMode': creds.passwordMode,
            if (creds.passwordMode == 'timed' && creds.ttlMinutes > 0)
              'passwordTTLMinutes': creds.ttlMinutes,
          });
        }
        await refreshProxyList();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text('Added ${result.proxies.length} proxy(ies)')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Detection failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDetecting = false);
    }
  }
}


class _ProxyCredentials {
  final String username;
  final String password;
  final String passwordMode;
  final int ttlMinutes;

  const _ProxyCredentials({
    required this.username,
    required this.password,
    required this.passwordMode,
    required this.ttlMinutes,
  });
}
