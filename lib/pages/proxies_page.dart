import 'package:flutter/material.dart';
import 'package:lux/const/const.dart';
import 'package:lux/model/app.dart';
import 'package:lux/tr.dart';
import 'package:lux/util/cert_installer.dart';
import 'package:lux/util/installed_certs_store.dart';
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
  /// Dashboard registers a refresh callback here so the header bar can
  /// trigger a list refresh after adding a proxy from the + button.
  final void Function(VoidCallback)? onRegisterRefresh;

  const ProxiesPage(
      {super.key,
      required this.coreManager,
      required this.curProxyInfo,
      required this.onCurProxyInfoChange,
      required this.dashboardUrl,
      this.onRegisterRefresh});

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

  bool _isScanningProxy = false;

  var isCollapsedMap = <String, bool>{};

  Future<void> refreshProxyList() async {
    final proxyList = await widget.coreManager.getProxyList();
    // Fetch subscriptions in parallel with proxy list
    final subscriptionListValue =
        await widget.coreManager.getSubscriptionList();
    if (!mounted) return;
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
          isCollapsedMap[key] = true;
        }
      }
    });
  }

  // Lightweight refresh — only fetches the proxy list (skips subscriptions).
  // Use after add/edit/delete where subscription list didn't change.
  Future<void> _refreshProxiesOnly() async {
    final proxyList = await widget.coreManager.getProxyList();
    if (!mounted) return;
    setState(() {
      proxyListGroup = ProxyListGroup(
          allProxies: proxyList.proxies,
          subscriptions: subscriptionList,
          selectedId: proxyList.id);
      Provider.of<AppStateModel>(context, listen: false)
          .updateSelectedProxyId(proxyListGroup.selectedId);
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
    // Register refresh callback so the header bar's + button can trigger us
    widget.onRegisterRefresh?.call(() => _refreshProxiesOnly());
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
    if (item.id == proxyListGroup.selectedId) {
      widget.onCurProxyInfoChange("");
    }
    _refreshProxiesOnly();
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
        onSaved: () => _refreshProxiesOnly(), // skip subscription fetch
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
      _refreshProxiesOnly();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to lock password: $e')),
      );
    }
  }

  // ── Proxy scan ──────────────────────────────────────────────────────────

  Future<void> _scanForProxy() async {
    if (_isScanningProxy) return;
    setState(() => _isScanningProxy = true);
    try {
      final detected = await widget.coreManager.detectNetworkProxy();
      if (!mounted) return;
      if (detected == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No network proxy detected on this network')),
        );
        return;
      }
      // Always probe SSL directly — transparent proxy intercepts port 443 at network
      // level so cert is visible without auth. Only skip if no proxy was found.
      final ssl = await widget.coreManager.getSslBumpStatus(fresh: true);
      if (!mounted) return;
      await _showScanResultDialog(detected, ssl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scan failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isScanningProxy = false);
    }
  }

  Future<void> _showScanResultDialog(DetectedProxy detected, SslBumpStatus ssl) async {
    // Pre-fill name from SSL cert org name if available
    final defaultName = ssl.certInfo?.organizationName.isNotEmpty == true
        ? ssl.certInfo!.organizationName
        : detected.host;
    final nameCtrl   = TextEditingController(text: defaultName);
    final serverCtrl = TextEditingController(text: detected.host);
    final portCtrl   = TextEditingController(text: detected.port);
    final userCtrl   = TextEditingController();
    final passCtrl   = TextEditingController();
    final userFocus  = FocusNode();
    final passFocus  = FocusNode();
    bool obscure = true;

    const sourceLabel = {
      'dhcp_wpad':      'DHCP/WPAD',
      'wpad_dns':       'WPAD DNS',
      'dhcp_option252': 'DHCP',
      'pac':            'PAC',
      'scutil':         'System',
    };

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.wifi_find, size: 20),
            SizedBox(width: 8),
            Text('Network Proxy Detected', style: TextStyle(fontSize: 16)),
          ]),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Proxy address + source badge
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(children: [
                      const Icon(Icons.dns, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(detected.address,
                            style: const TextStyle(fontSize: 14,
                                fontWeight: FontWeight.w500)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          sourceLabel[detected.source] ?? detected.source,
                          style: TextStyle(fontSize: 10,
                              color: Theme.of(ctx).colorScheme.onSecondaryContainer),
                        ),
                      ),
                    ]),
                  ),

                  // SSL status
                  const SizedBox(height: 10),
                  if (ssl.detected) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade800.withValues(alpha: 0.12),
                        border: Border.all(color: Colors.orange.shade600),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(children: [
                        Icon(Icons.security, size: 14, color: Colors.orange),
                        SizedBox(width: 6),
                        Flexible(child: Text('SSL Interception Detected',
                            style: TextStyle(fontSize: 12,
                                fontWeight: FontWeight.w600, color: Colors.orange))),
                      ]),
                    ),
                  ] else if (ssl.error != null &&
                      (ssl.error!.contains('407') || detected.needsAuth)) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade800.withValues(alpha: 0.10),
                        border: Border.all(color: Colors.blue.shade600),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(children: [
                        Icon(Icons.info_outline, size: 13, color: Colors.blue),
                        SizedBox(width: 4),
                        Flexible(child: Text(
                          'SSL check requires credentials — enter below and add proxy.',
                          style: TextStyle(fontSize: 11))),
                      ]),
                    ),
                  ] else if (ssl.error == null && !detected.needsAuth) ...[
                    const Row(children: [
                      Icon(Icons.shield_outlined, size: 13, color: Colors.green),
                      SizedBox(width: 4),
                      Text('No SSL interception detected',
                          style: TextStyle(fontSize: 12, color: Colors.green)),
                    ]),
                  ],

                  // Fields
                  const SizedBox(height: 14),
                  const Divider(),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Name', isDense: true,
                        border: OutlineInputBorder()),
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(flex: 3, child: TextField(
                      controller: serverCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Server', isDense: true,
                          border: OutlineInputBorder()),
                      style: const TextStyle(fontSize: 13),
                    )),
                    const SizedBox(width: 8),
                    Expanded(flex: 1, child: TextField(
                      controller: portCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Port', isDense: true,
                          border: OutlineInputBorder()),
                      style: const TextStyle(fontSize: 13),
                      keyboardType: TextInputType.number,
                    )),
                  ]),
                  const SizedBox(height: 8),
                  TextField(
                    controller: userCtrl,
                    focusNode: userFocus,
                    decoration: const InputDecoration(
                        labelText: 'Username (optional)', isDense: true,
                        border: OutlineInputBorder()),
                    style: const TextStyle(fontSize: 13),
                    onSubmitted: (_) => FocusScope.of(ctx).requestFocus(passFocus),
                  ),
                  const SizedBox(height: 8),
                  StatefulBuilder(builder: (_, setObs) => TextField(
                    controller: passCtrl,
                    focusNode: passFocus,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'Password (optional)',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined, size: 16),
                        onPressed: () => setObs(() => obscure = !obscure),
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                  )),
                  if (detected.needsAuth) ...[
                    const SizedBox(height: 4),
                    const Row(children: [
                      Icon(Icons.lock_outline, size: 12, color: Colors.orange),
                      SizedBox(width: 4),
                      Text('407 auth required',
                          style: TextStyle(fontSize: 11, color: Colors.orange)),
                    ]),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final server = serverCtrl.text.trim();
                final port   = portCtrl.text.trim();
                final user   = userCtrl.text;
                final pass   = passCtrl.text;
                final name   = nameCtrl.text.trim().isNotEmpty
                    ? nameCtrl.text.trim()
                    : 'Network Proxy ($server)';
                try {
                  await widget.coreManager.addProxy({
                    'type': 'http',
                    'name': name,
                    'server': server,
                    'port': int.tryParse(port) ?? 8080,
                    if (user.isNotEmpty) 'username': user,
                    if (pass.isNotEmpty) 'password': pass,
                  });

                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Proxy added')));

                  // Re-probe with credentials if provided
                  String proxyAddr;
                  if (user.isNotEmpty) {
                    final eu = Uri.encodeComponent(user);
                    final ep = Uri.encodeComponent(pass);
                    proxyAddr = '$eu:$ep@$server:$port';
                  } else {
                    proxyAddr = '$server:$port';
                  }
                  final freshSsl = await widget.coreManager.getSslBumpStatus(
                      proxyAddr: proxyAddr, fresh: true);
                  if (!mounted) return;
                  if (freshSsl.detected && freshSsl.hasCert) {
                    final fp = freshSsl.certInfo?.sha256Fingerprint ?? '';
                    final certOrg = freshSsl.certInfo?.organizationName ?? '';
                    // Rename proxy to cert org name if different from what was entered
                    if (certOrg.isNotEmpty && name != certOrg) {
                      try {
                        final proxyList = await widget.coreManager.getProxyList();
                        final added = proxyList.proxies.lastWhere(
                            (p) => p.server == server, orElse: () => proxyList.proxies.last);
                        await widget.coreManager.updateProxy(added.id, {
                          'name': certOrg, 'server': server,
                          'port': int.tryParse(port) ?? 8080,
                          if (user.isNotEmpty) 'username': user,
                          if (pass.isNotEmpty) 'password': pass,
                        });
                      } catch (_) {}
                    }
                    if (!await InstalledCertsStore.isFullyInstalled(fp)) {
                      _showCertTrustDialog(freshSsl, fp);
                    }
                  }
                  // Refresh after rename so the final name shows immediately
                  await _refreshProxiesOnly();
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Add to Lux'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose(); serverCtrl.dispose(); portCtrl.dispose();
    userCtrl.dispose(); passCtrl.dispose();
    userFocus.dispose(); passFocus.dispose();
  }

  void _showCertTrustDialog(SslBumpStatus ssl, String fingerprint) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.security, color: Colors.orange, size: 20),
          SizedBox(width: 8),
          Text('Proxy intercepts HTTPS', style: TextStyle(fontSize: 15)),
        ]),
        content: const SizedBox(
          width: 380,
          child: Text(
            'SSL inspection detected. Trust the proxy\'s certificate to browse securely.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Skip'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                final pem = await widget.coreManager.getSslBumpCert();
                if (pem == null || pem.isEmpty) return;
                final result = await CertInstaller.install(pem);
                if (result.success) {
                  final stores = result.steps
                      .where((s) => s.success).map((s) => s.name).toList();
                  await InstalledCertsStore.markInstalled(fingerprint, stores);
                }
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(result.success
                      ? 'Certificate installed' : 'Partial install — check Settings'),
                  backgroundColor: result.success
                      ? Colors.green.shade700 : Colors.orange.shade700,
                ));
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Install failed: $e')));
              }
            },
            child: const Text('Trust & Install'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _isScanningProxy ? null : _scanForProxy,
                icon: _isScanningProxy
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_find, size: 16),
                label: Text(_isScanningProxy ? 'Scanning…' : 'Scan for Proxy'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Proxy list
        Expanded(
          child: RadioGroup<String>(
            groupValue: proxyListGroup.selectedId,
            onChanged: handleSelectProxy,
            child: proxyListGroup.groups.isEmpty
                ? const SizedBox()
                : ListView.builder(
                    itemCount: proxyListGroup.groups.length,
                    itemBuilder: (context, index) {
                      return ProxyListCard(
                        proxyList: proxyListGroup.groups[index],
                        key: Key(proxyListGroup.groups[index].id),
                        isCollapsed: getIsCollapsed(proxyListGroup.groups[index]),
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
}
