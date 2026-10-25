import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lux/util/t_text.dart';
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

  // ── Auto-switch ────────────────────────────────────────────────────────────
  bool _autoSwitchEnabled = false;
  bool _autoSwitching = false; // currently running a probe cycle
  String _autoSwitchState = ''; // 'corporate'|'direct'|'no_internet'|''
  String _autoSwitchProxyName = '';

  AppStateModel? _appState;
  int _lastProxyRevision = 0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    refreshData();
    _loadAutoSwitchState();
    // Listen for proxy-list changes triggered elsewhere (e.g. add from the
    // header bar) so the list refreshes without a manual page switch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _appState = Provider.of<AppStateModel>(context, listen: false);
      _lastProxyRevision = _appState!.proxyListRevision;
      _appState!.addListener(_onAppStateChanged);
    });
  }

  void _onAppStateChanged() {
    if (!mounted || _appState == null) return;
    if (_appState!.proxyListRevision != _lastProxyRevision) {
      _lastProxyRevision = _appState!.proxyListRevision;
      refreshData();
    }
  }

  Future<void> _loadAutoSwitchState() async {
    final enabled = await readAutoSwitchEnabled();
    if (!mounted) return;
    setState(() => _autoSwitchEnabled = enabled);
    if (enabled) {
      final status = await widget.coreManager.getNetSwitchStatus();
      if (!mounted) return;
      setState(() {
        _autoSwitchState = status['state'] as String? ?? '';
        _autoSwitchProxyName = status['activeProxyName'] as String? ?? '';
        _autoSwitching = status['probing'] as bool? ?? false;
      });
    }
  }

  Future<void> _triggerAutoSwitch() async {
    if (_autoSwitching) return;
    setState(() => _autoSwitching = true);
    await widget.coreManager.triggerNetSwitch();
    // Poll until probing finishes (max 15s)
    for (int i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      final status = await widget.coreManager.getNetSwitchStatus();
      final probing = status['probing'] as bool? ?? false;
      setState(() {
        _autoSwitchState = status['state'] as String? ?? '';
        _autoSwitchProxyName = status['activeProxyName'] as String? ?? '';
        _autoSwitching = probing;
      });
      if (!probing) {
        await refreshProxyList(); // reflect new selection
        return;
      }
    }
    if (mounted) setState(() => _autoSwitching = false);
  }

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
    if (id == null) return;
    try {
      setState(() => isLoadingProxyRadio = true);
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
      // Record manual selection for auto-switch: sets 10-min hold + lastUserProxy
      final proxy = proxyListGroup.allProxies.firstWhere(
          (p) => p.id == id, orElse: () => ProxyItem(id, '', null, null, null, ''));
      final name = proxy.name.isNotEmpty
          ? proxy.name
          : '${proxy.server ?? ''}:${proxy.port ?? ''}';
      await writeLastUserProxyId(id);
      await widget.coreManager.notifyManualSelect(id, name);
    } finally {
      setState(() => isLoadingProxyRadio = false);
    }
  }

  @override
  void onWindowFocus() {
    refreshData();
  }

  @override
  void dispose() {
    _detectTimer?.cancel();
    _appState?.removeListener(_onAppStateChanged);
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

  /// Create a copy of a proxy: take its full raw config, drop the id/select
  /// state, rename to "… (copy)", and add it as a new proxy. The core assigns
  /// a fresh id on add.
  void _handleDuplicateItem(ProxyItem item) async {
    final detail = await widget.coreManager.getProxyDetail(item.id);
    if (!mounted || detail == null) return;
    try {
      final data = Map<String, dynamic>.from(detail.raw);
      // Never carry over identity/selection or subscription linkage.
      data.remove('id');
      data.remove('subscription');
      // Start the copy with a fresh (unlocked) password state; the password
      // value itself is kept so the copy works immediately.
      data.remove('passwordLocked');
      data.remove('passwordExpired');
      data.remove('passwordSetAt');
      final baseName = (data['name'] as String?)?.trim();
      data['name'] = (baseName == null || baseName.isEmpty)
          ? 'copy'
          : '$baseName (copy)';
      await widget.coreManager.addProxy(data);
      await refreshData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tl(context, 'Proxy duplicated'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to duplicate: $e')),
      );
    }
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
      case ProxyItemAction.duplicate:
        _handleDuplicateItem(item);
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
        // Toolbar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              // Auto-switch trigger button (only when enabled)
              if (_autoSwitchEnabled) ...[
                _autoSwitching
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 1.5))
                    : Tooltip(
                        message: 'Check network and auto-select best proxy',
                        child: IconButton(
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          onPressed: _triggerAutoSwitch,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                        ),
                      ),
                // Status chip
                if (_autoSwitchState.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _AutoSwitchChip(
                      state: _autoSwitchState,
                      proxyName: _autoSwitchProxyName),
                  const SizedBox(width: 4),
                ],
              ],
              const Spacer(),
              _isDetecting
                  ? SizedBox(
                      width: 140,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${tl(context, 'Detecting')} ${(_detectProgress * 100).round()}%',
                            style: const TextStyle(fontSize: 11),
                          ),
                          const SizedBox(height: 3),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _detectProgress,
                              minHeight: 3,
                            ),
                          ),
                        ],
                      ),
                    )
                  : TextButton.icon(
                      onPressed: _detectProxies,
                      icon: const Icon(Icons.wifi_find, size: 16),
                      label: const TText('Detect Proxy',
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
                    child: TText('No proxies configured',
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
  double _detectProgress = 0; // 0..1 fake progress while detecting
  Timer? _detectTimer;

  /// Starts a fake progress animation that ramps to 30%, slows to 60%,
  /// crawls to 90% and holds — same UX as the download page. The real
  /// detect call replaces it with 100% when it completes.
  void _startDetectProgress() {
    _detectProgress = 0.01;
    int phase = 0;
    _detectTimer?.cancel();
    _detectTimer = Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final rnd = math.Random();
      double p = _detectProgress * 100;
      if (phase == 0) {
        p += 1.5 + rnd.nextDouble() * 2;
        if (p >= 30) { p = 30; phase = 1; }
      } else if (phase == 1) {
        p += 0.3 + rnd.nextDouble() * 0.5;
        if (p >= 60) { p = 60; phase = 2; }
      } else if (phase == 2) {
        p += 0.1 + rnd.nextDouble() * 0.2;
        if (p >= 90) { p = 90; phase = 3; }
      }
      setState(() => _detectProgress = p / 100);
    });
  }

  void _stopDetectProgress() {
    _detectTimer?.cancel();
    _detectTimer = null;
  }

  Future<void> _checkCertForProxy(DetectedProxy proxy, _ProxyCredentials creds) async {
    try {
      final result = await widget.coreManager.checkCert(
        server: proxy.host,
        port: int.tryParse(proxy.port) ?? 8080,
        username: creds.username,
        password: creds.password,
      );

      if (!mounted) return;

      if (result.error.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cert check: ${result.error}')),
        );
        return;
      }

      if (!result.intercepted) {
        // No MITM — all good, nothing to show
        return;
      }

      // Show the intercepting CA and offer to trust it
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.security, size: 22, color: Colors.orange),
            SizedBox(width: 8),
            TText('SSL Interception Detected'),
          ]),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TText(
                  'This proxy intercepts HTTPS traffic with a corporate certificate. '
                  'Some apps may not work until you trust this CA.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                _certRow('Issuer', result.issuer),
                _certRow('Subject', result.subject),
                _certRow('Valid', '${result.notBefore} to ${result.notAfter}'),
                _certRow('SHA256', result.sha256.length > 16
                    ? '${result.sha256.substring(0, 16)}...'
                    : result.sha256),
                const SizedBox(height: 12),
                const TText(
                  'To trust this certificate, it needs to be added to your '
                  'system keychain. This requires your Mac password.',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const TText('Skip'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                await _installCert(result);
              },
              icon: const Icon(Icons.verified_user, size: 16),
              label: const TText('Trust Certificate'),
            ),
          ],
        ),
      );
    } catch (e) {
      // Non-critical — don't block the flow
      debugPrint('Cert check failed: $e');
    }
  }

  Widget _certRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: TText(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  Future<void> _installCert(CertCheckResult cert) async {
    // Use lux_core's install-cert endpoint — it runs elevated and avoids the
    // osascript admin-password prompt.  If lux_core isn't running yet, fall
    // back to the osascript path.
    bool installed = false;
    try {
      await widget.coreManager.installCert(cert.pem);
      installed = true;
    } catch (_) {
      // lux_core unavailable — try osascript fallback
    }

    if (!installed) {
      try {
        final tmpDir = await Directory.systemTemp.createTemp('lux_cert');
        final certFile = File('${tmpDir.path}/corporate_ca.pem');
        await certFile.writeAsString(cert.pem);
        final script = 'do shell script '
            '"security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '
            '${certFile.path}" '
            'with prompt "Lux needs to install the corporate CA certificate" '
            'with administrator privileges';
        final r = await Process.run('/usr/bin/osascript', ['-e', script]);
        installed = r.exitCode == 0;
        try { await certFile.delete(); await tmpDir.delete(); } catch (_) {}
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Certificate install failed: $e')),
          );
        }
        return;
      }
    }

    if (!installed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('Certificate install cancelled')),
        );
      }
      return;
    }

    if (!mounted) return;

    // Re-check after a short delay to confirm trust — stops the infinite loop.
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 5),
        content: TText(
          'Certificate installed. Test the proxy — if still failing, the cert may not have installed correctly.',
        ),
      ),
    );
  }

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
                  decoration: InputDecoration(
                    labelText: tl(ctx, 'Username'),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: tl(ctx, 'Password'),
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
                  decoration: InputDecoration(
                    labelText: tl(ctx, 'Password type'),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'persistent', child: TText('Persistent (saved)')),
                    DropdownMenuItem(value: 'timed', child: TText('Timed (expires)')),
                    DropdownMenuItem(value: 'one-time', child: TText('One-time (cleared after use)')),
                  ],
                  onChanged: (v) => setDialogState(() => passwordMode = v!),
                ),
                if (passwordMode == 'timed') ...[
                  const SizedBox(height: 12),
                  TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: tl(ctx, 'Expires after (minutes)'),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    controller: TextEditingController(text: '$ttlMinutes'),
                    onChanged: (v) => ttlMinutes = int.tryParse(v) ?? 60,
                  ),
                ],
                const SizedBox(height: 8),
                const TText(
                  'Leave empty if the proxy does not require authentication.',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const TText('Cancel'),
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
              child: const TText('Add Proxy'),
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
    _startDetectProgress();
    try {
      final result = await widget.coreManager.detectProxies();
      // Detection done — snap the bar to 100% before showing results
      _stopDetectProgress();
      if (mounted) setState(() => _detectProgress = 1.0);
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
          title: const TText('Detected Proxies'),
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
                      subtitle: const TText('HTTP Proxy'),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const TText('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Add ${result.proxies.length} Prox${result.proxies.length == 1 ? "y" : "ies"}'),
            ),
          ],
        ),
      );

      if (added == true) {
        // Step 2: Prompt for credentials with retry on auth failure
        final firstProxy = result.proxies.first;
        final port = int.tryParse(firstProxy.port) ?? 8080;
        _ProxyCredentials? creds;
        CertCheckResult? certResult;

        while (true) {
          creds = await _promptCredentials(firstProxy);
          if (creds == null) return;

          // Step 3: Validate credentials via cert check
          try {
            certResult = await widget.coreManager.checkCert(
              server: firstProxy.host,
              port: port,
              username: creds.username,
              password: creds.password,
            );
          } catch (_) {
            // Network/timeout error - proceed without cert info
            break;
          }

          // Check if auth failed (407 in response body)
          if (certResult != null && certResult.error.isNotEmpty) {
            final err = certResult.error.toLowerCase();
            if (err.contains('407') || err.contains('auth') || err.contains('denied')) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: TText('Wrong password — try again'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
              continue; // loop back to credentials prompt
            }
          }
          break; // auth succeeded or no error
        }
        if (creds == null) return;

        // Step 4: Derive proxy name from cert issuer (only when MITM is detected)
        String suggestedName = firstProxy.host;
        if (certResult != null && certResult.intercepted && certResult.issuer.isNotEmpty) {
          // Try to extract O= (Organization) from the issuer DN
          final orgMatch = RegExp(r'O=([^,]+)').firstMatch(certResult.issuer);
          if (orgMatch != null) {
            suggestedName = orgMatch.group(1)!.trim();
          } else {
            // Fall back to CN= or the whole issuer string
            final cnMatch = RegExp(r'CN=([^,]+)').firstMatch(certResult.issuer);
            suggestedName = cnMatch != null ? cnMatch.group(1)!.trim() : certResult.issuer;
          }
        }
        // Step 5: Let user confirm or override the name (no duplicates)
        final existingNames = proxyListGroup.allProxies.map((p) => p.name.toLowerCase()).toSet();
        final nameCtrl = TextEditingController(text: suggestedName);
        String? nameError;
        final confirmedName = await showDialog<String>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) {
              void validate(String v) {
                final trimmed = v.trim().toLowerCase();
                setDialogState(() {
                  if (trimmed.isEmpty) {
                    nameError = 'Name cannot be empty';
                  } else if (existingNames.contains(trimmed)) {
                    nameError = 'A proxy with this name already exists';
                  } else {
                    nameError = null;
                  }
                });
              }

              return AlertDialog(
                title: const TText('Name this proxy'),
                content: TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: tl(ctx, 'Proxy name'),
                    hintText: tl(ctx, 'e.g. Office, School, Home'),
                    errorText: nameError,
                  ),
                  autofocus: true,
                  onChanged: validate,
                  onSubmitted: (v) {
                    if (nameError == null && v.trim().isNotEmpty) {
                      Navigator.pop(ctx, v.trim());
                    }
                  },
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, null),
                    child: const TText('Cancel'),
                  ),
                  FilledButton(
                    onPressed: nameError == null && nameCtrl.text.trim().isNotEmpty
                        ? () => Navigator.pop(ctx, nameCtrl.text.trim())
                        : null,
                    child: const TText('Add'),
                  ),
                ],
              );
            },
          ),
        );
        nameCtrl.dispose();
        if (confirmedName == null || confirmedName.isEmpty) return;

        // Step 6: Add the proxy
        for (final p in result.proxies) {
          await widget.coreManager.addProxy({
            'name': confirmedName,
            'type': 'http',
            'server': p.host,
            'port': int.tryParse(p.port) ?? 8080,
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
            SnackBar(content: Text('Added ${result.proxies.length} proxy(ies) as "$confirmedName"')),
          );
          // Show SSL interception info if detected
          if (certResult != null && certResult.intercepted) {
            _checkCertForProxy(firstProxy, creds);
          }
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
      _stopDetectProgress();
      if (mounted) {
        setState(() {
          _isDetecting = false;
          _detectProgress = 0;
        });
      }
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

/// Small status chip shown next to the auto-switch button.
class _AutoSwitchChip extends StatelessWidget {
  final String state;
  final String proxyName;
  const _AutoSwitchChip({required this.state, required this.proxyName});

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (state) {
      'corporate' => (Colors.green, Icons.business, proxyName.isNotEmpty ? proxyName : 'Proxy'),
      'direct'    => (Colors.blue, Icons.home_outlined, 'Direct'),
      'no_internet' => (Colors.red, Icons.signal_wifi_off, 'No internet'),
      _ => (Colors.grey, Icons.swap_horiz, state),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        border: Border.all(color: color.withAlpha(120)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(fontSize: 10, color: color),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}
