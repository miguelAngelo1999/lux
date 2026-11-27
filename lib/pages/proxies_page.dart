import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/const/const.dart';
import 'package:lux/model/app.dart';
import 'package:lux/tr.dart';
import 'package:lux/widget/backup_proxies_dialog.dart';
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/lux_scroll_edge_fade.dart';
import 'package:lux/widget/password_peek_dialog.dart';
import 'package:lux/widget/pac_rules_dialog.dart';
import 'package:lux/widget/proxy_edit_dialog.dart';
import 'package:lux/widget/proxy_list_card.dart';
import 'package:lux/widget/proxy_list_item.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../core/core_config.dart';
import '../core/core_manager.dart';
import '../error.dart';
import '../util/cert_trust.dart';

class ProxiesPage extends StatefulWidget {
  final CoreManager coreManager;
  final String curProxyInfo;
  final String dashboardUrl;
  final void Function(String) onCurProxyInfoChange;
  final Future<void> Function(ProxyItem item)? onPeekPassword;
  const ProxiesPage(
      {super.key,
      required this.coreManager,
      required this.curProxyInfo,
      required this.onCurProxyInfoChange,
      required this.dashboardUrl,
      this.onPeekPassword});

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

  // ── Auto Home/Office & Stay connected ──────────────────────────────────────
  bool _autoSwitchEnabled = false;
  bool _stayConnectedEnabled = false;
  String _backupMode = 'all'; // 'all' | 'selected'
  List<String> _backupProxyIds = const [];
  bool _autoSwitching = false; // currently running a probe cycle
  String _autoSwitchState = ''; // 'corporate'|'failover'|'direct'|'captive_portal'|'no_internet'|''
  String _autoSwitchProxyName = '';
  String _autoSwitchPreferredName = '';

  AppStateModel? _appState;
  int _lastProxyRevision = 0;

  final Map<String, ProxyTestStatus> _testStatuses = {};
  final ProxyItemController _selectedItemController = ProxyItemController();
  bool _isConnecting = false;

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
    final stayConnected = await readStayConnectedEnabled();
    final backupMode = await readBackupMode();
    final backupIds = await readBackupProxyIds();
    if (!mounted) return;
    setState(() {
      _autoSwitchEnabled = enabled;
      _stayConnectedEnabled = stayConnected;
      _backupMode = backupMode;
      _backupProxyIds = backupIds;
    });
    if (enabled || stayConnected) {
      final status = await widget.coreManager.getNetSwitchStatus();
      if (!mounted) return;
      setState(() {
        _autoSwitchState = status['state'] as String? ?? '';
        _autoSwitchProxyName = status['activeProxyName'] as String? ?? '';
        _autoSwitchPreferredName = status['preferredProxyName'] as String? ?? '';
        _autoSwitching = status['probing'] as bool? ?? false;
      });
    }
  }

  Future<void> _toggleAutoSwitch(bool enabled) async {
    await writeAutoSwitchEnabled(enabled);
    await widget.coreManager.setNetSwitchEnabled(enabled);
    if (enabled) {
      final lastId = await readLastUserProxyId();
      await widget.coreManager.syncNetSwitchConfig(lastId);
    }
    if (!mounted) return;
    setState(() {
      _autoSwitchEnabled = enabled;
      if (!enabled && !_stayConnectedEnabled) {
        _autoSwitchState = '';
        _autoSwitchProxyName = '';
        _autoSwitchPreferredName = '';
        _autoSwitching = false;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled
            ? tl(context, 'Auto Home/Office enabled')
            : tl(context, 'Auto Home/Office disabled')),
        duration: const Duration(seconds: 2),
      ),
    );
    if (enabled) {
      unawaited(_triggerAutoSwitch());
    }
  }

  Future<void> _toggleStayConnected(bool enabled) async {
    await writeStayConnectedEnabled(enabled);
    await widget.coreManager.setStayConnectedEnabled(enabled);
    if (enabled) {
      final lastId = await readLastUserProxyId();
      await widget.coreManager.syncNetSwitchConfig(
        lastId,
        stayConnected: true,
        backupMode: _backupMode,
        backupProxyIds: _backupProxyIds,
      );
    }
    if (!mounted) return;
    setState(() {
      _stayConnectedEnabled = enabled;
      if (!enabled && !_autoSwitchEnabled) {
        _autoSwitchState = '';
        _autoSwitchProxyName = '';
        _autoSwitchPreferredName = '';
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled
            ? tl(context, 'Stay connected enabled')
            : tl(context, 'Stay connected disabled')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openBackupProxiesDialog() async {
    final choice = await showDialog<BackupPoolChoice>(
      context: context,
      builder: (_) => BackupProxiesDialog(
        proxies: proxyListGroup.allProxies,
        initialMode: _backupMode,
        initialSelectedIds: _backupProxyIds,
      ),
    );
    if (choice == null) return;
    await writeBackupMode(choice.mode);
    await writeBackupProxyIds(choice.proxyIds);
    await widget.coreManager.setBackupConfig(
      mode: choice.mode,
      proxyIds: choice.proxyIds,
    );
    if (!mounted) return;
    setState(() {
      _backupMode = choice.mode;
      _backupProxyIds = choice.proxyIds;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          choice.mode == 'selected'
              ? tl(context, 'Backup proxies updated ({count} selected)')
                  .replaceAll('{count}', '${choice.proxyIds.length}')
              : tl(context, 'Backup proxies set to all saved proxies'),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
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
        _autoSwitchPreferredName = status['preferredProxyName'] as String? ?? '';
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
    if (!mounted) return;
    setState(() {
      subscriptionList = subscriptionListValue.value;
      proxyListGroup = ProxyListGroup(
          allProxies: proxyList.proxies,
          subscriptions: subscriptionList,
          selectedId: proxyList.id);

      for (var group in proxyListGroup.groups) {
        var key = group.id;
        if (!isCollapsedMap.containsKey(key)) {
          isCollapsedMap[key] = true;
        }
      }
    });
    Provider.of<AppStateModel>(context, listen: false)
        .updateSelectedProxyId(proxyListGroup.selectedId);
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
      if (data['server'] is String) data['server'] = (data['server'] as String).trim();
      if (data['username'] is String) data['username'] = (data['username'] as String).trim();
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
      case ProxyItemAction.viewPacRules:
        _handleViewPacRules(item);
    }
  }

  void _handleViewPacRules(ProxyItem item) async {
    await PacRulesDialog.show(
      context: context,
      coreManager: widget.coreManager,
      proxyId: item.id,
      proxyName: item.name.isNotEmpty
          ? item.name
          : '${item.server ?? ''}:${item.port ?? ''}',
      initialPacUrl: item.pacUrl,
    );
  }

  void _handlePeekPassword(ProxyItem item) async {
    if (widget.onPeekPassword != null) {
      await widget.onPeekPassword!(item);
      return;
    }
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

  Future<void> _connectFromBanner() async {
    if (_isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      await widget.coreManager.toggleConnection(true);
    } catch (e) {
      if (mounted) {
        final msg = e is CoreElevationCancelledError
            ? e.message
            : 'Could not connect. Check your proxy and try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: TText(msg)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  String _selectedProxyDisplayName() {
    final selectedId = proxyListGroup.selectedId;
    final selected = proxyListGroup.allProxies
        .where((p) => p.id == selectedId)
        .firstOrNull;
    if (selected != null) {
      if (selected.name.isNotEmpty) return selected.name;
      if ((selected.server ?? '').isNotEmpty) {
        return '${selected.server}:${selected.port ?? ''}';
      }
    }
    return widget.curProxyInfo;
  }

  ProxyItem? _selectedProxyItem() {
    final selectedId = proxyListGroup.selectedId;
    return proxyListGroup.allProxies
        .where((p) => p.id == selectedId)
        .firstOrNull;
  }

  Widget _buildStatusBanner(BuildContext context, AppStateModel appState) {
    final tokens = LuxTokens.of(context);
    final selectedStatus =
        _testStatuses[proxyListGroup.selectedId] ?? const ProxyTestStatus();
    final proxyName = _selectedProxyDisplayName();
    final selectedProxy = _selectedProxyItem();
    final serverEndpoint = (selectedProxy != null &&
            (selectedProxy.server ?? '').isNotEmpty)
        ? '${selectedProxy.server}:${selectedProxy.port ?? ''}'
        : '';

    final Color accent;
    final LuxGlyph glyph;
    final bool showLiveDot;
    final String message;
    final String? subtitle;
    final Widget? badge;
    final List<Widget> actions;

    if (appState.pausedForCaptivePortal) {
      accent = tokens.amber;
      glyph = LuxGlyph.wifiLock;
      showLiveDot = false;
      message = tl(context,
          'Captive Wi-Fi detected — sign in; Lux will resume automatically');
      subtitle = null;
      badge = null;
      final portalUrl = appState.captivePortalUrl;
      final portalUri =
          (portalUrl != null && portalUrl.isNotEmpty) ? Uri.tryParse(portalUrl) : null;
      final safePortalUri = (portalUri != null &&
              (portalUri.scheme == 'http' || portalUri.scheme == 'https') &&
              portalUri.host.isNotEmpty)
          ? portalUri
          : null;
      actions = [
        if (safePortalUri != null)
          _bannerActionButton(
            key: const Key('banner-action-captive-login'),
            label: tl(context, 'Open login'),
            color: accent,
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                final ok = await launchUrl(
                  safePortalUri,
                  mode: LaunchMode.externalApplication,
                );
                if (!ok && mounted) {
                  messenger.showSnackBar(
                    SnackBar(content: Text(safePortalUri.toString())),
                  );
                }
              } catch (_) {
                if (mounted) {
                  messenger.showSnackBar(
                    SnackBar(content: Text(safePortalUri.toString())),
                  );
                }
              }
            },
          ),
      ];
    } else if (appState.pausedForNoNetwork) {
      accent = tokens.amber;
      glyph = LuxGlyph.wifiOff;
      showLiveDot = false;
      message = tl(context, 'Paused — waiting for Wi-Fi or Ethernet');
      subtitle = null;
      badge = null;
      actions = const [];
    } else if (selectedStatus.state == TestState.authError) {
      accent = tokens.danger;
      glyph = LuxGlyph.lock;
      showLiveDot = false;
      message =
          tl(context, 'Login required — check your username and password below');
      subtitle = null;
      badge = null;
      actions = [
        _bannerActionButton(
          key: const Key('banner-action-auth'),
          label: tl(context, 'Enter password'),
          color: accent,
          onPressed: () => _selectedItemController.focusPassword?.call(),
        ),
      ];
    } else if (selectedStatus.state == TestState.certError) {
      accent = tokens.amber;
      glyph = LuxGlyph.shieldAlert;
      showLiveDot = false;
      message = tl(context, 'Proxy certificate not trusted');
      subtitle = null;
      badge = null;
      actions = [
        _bannerActionButton(
          key: const Key('banner-action-trust'),
          label: tl(context, 'Trust'),
          color: accent,
          onPressed: () => _selectedItemController.promptCertTrust?.call(),
        ),
      ];
    } else if (selectedStatus.state == TestState.unreachable) {
      accent = tokens.danger;
      glyph = LuxGlyph.alertCircle;
      showLiveDot = false;
      message = tl(context, 'Proxy unreachable on this network');
      subtitle = null;
      badge = null;
      actions = [
        _bannerActionButton(
          key: const Key('banner-action-test'),
          label: tl(context, 'Test'),
          color: accent,
          onPressed: () => _selectedItemController.runTest?.call(),
        ),
        const SizedBox(width: 6),
        _bannerActionButton(
          key: const Key('banner-action-detect'),
          label: tl(context, 'Detect Proxy'),
          color: accent,
          onPressed: _isDetecting ? null : _detectProxies,
        ),
      ];
    } else if (appState.isStarted) {
      accent = tokens.emerald;
      glyph = LuxGlyph.check;
      showLiveDot = true;
      message = proxyName.isNotEmpty
          ? tl(context, 'Connected via {name}').replaceAll('{name}', proxyName)
          : tl(context, 'Connected');
      subtitle = serverEndpoint.isNotEmpty ? serverEndpoint : null;
      if (selectedStatus.state == TestState.reachable) {
        final badgeColor =
            selectedStatus.pacReachable ? tokens.teal : tokens.emerald;
        final badgeText = selectedStatus.pacReachable
            ? 'PAC OK'
            : '${selectedStatus.latencyMs} ms';
        badge = Container(
          margin: const EdgeInsets.only(left: 8),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border:
                Border.all(color: badgeColor.withValues(alpha: 0.2), width: 0.75),
          ),
          child: Text(
            badgeText,
            style: selectedStatus.pacReachable
                ? TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: badgeColor,
                  )
                : luxMonoStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: badgeColor,
                  ),
          ),
        );
      } else {
        badge = null;
      }
      actions = const [];
    } else {
      accent = tokens.textMuted;
      glyph = LuxGlyph.power;
      showLiveDot = false;
      message = tl(context, 'Disconnected');
      subtitle = serverEndpoint.isNotEmpty ? serverEndpoint : null;
      badge = null;
      actions = [
        _bannerActionButton(
          key: const Key('banner-action-connect'),
          label: tl(context, 'Connect'),
          color: const Color(0xFF2563EB),
          filled: true,
          loading: _isConnecting,
          onPressed: (_isConnecting || proxyListGroup.selectedId.isEmpty)
              ? null
              : _connectFromBanner,
        ),
      ];
    }

    return Container(
      key: const Key('proxies-status-banner'),
      decoration: BoxDecoration(
        color: tokens.cardBg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: (showLiveDot || accent == tokens.textMuted)
              ? tokens.hairline
              : accent.withValues(alpha: 0.3),
          width: 0.75,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 2.5, color: accent),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 9, 11, 9),
              child: Row(
                children: [
                  if (showLiveDot)
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.14),
                      ),
                      child: Center(
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent,
                          ),
                        ),
                      ),
                    )
                  else
                    LuxIcon(glyph, size: 15, color: accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                message,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                  color: tokens.textPrimary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (badge != null) badge,
                          ],
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 1.5),
                          Text(
                            subtitle,
                            style: luxMonoStyle(
                              fontSize: 10.5,
                              color: tokens.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    ...actions,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bannerActionButton({
    Key? key,
    required String label,
    required Color color,
    required VoidCallback? onPressed,
    bool filled = false,
    bool loading = false,
  }) {
    final child = loading
        ? const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          )
        : Text(label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500));
    if (filled) {
      return SizedBox(
        height: 27,
        child: FilledButton(
          key: key,
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            minimumSize: const Size(0, 27),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          ),
          child: child,
        ),
      );
    }
    return SizedBox(
      height: 27,
      child: OutlinedButton(
        key: key,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 27),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: BorderSide(color: color.withValues(alpha: 0.65), width: 0.75),
          foregroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final appState = context.watch<AppStateModel>();
    return Column(
      children: [
        // Combined Hero Status Card + Auto-switch + Detect Proxy toolbar row
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compactDetect = constraints.maxWidth < 500;
              return Row(
                children: [
                  Expanded(child: _buildStatusBanner(context, appState)),
                  const SizedBox(width: 6),
                  // 1-click Auto Home/Office & Stay connected control
                  Tooltip(
                    message: (_autoSwitchEnabled || _stayConnectedEnabled)
                        ? tl(context,
                            'Auto Home/Office — uses your work proxy at the office and direct internet at home. Click to configure or check now.')
                        : tl(context,
                            'Auto Home/Office (OFF) — automatically switches between your work proxy at the office and direct internet at home.'),
                    child: _autoSwitching
                        ? SizedBox(
                            width: 34,
                            height: 34,
                            child: Center(
                              child: SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: tokens.cobalt,
                                ),
                              ),
                            ),
                          )
                        : PopupMenuButton<String>(
                            key: const Key('proxies-autoswitch-menu'),
                            tooltip: '',
                            padding: EdgeInsets.zero,
                            onSelected: (action) {
                              if (action == 'toggle') {
                                _toggleAutoSwitch(!_autoSwitchEnabled);
                              } else if (action == 'stay') {
                                _toggleStayConnected(!_stayConnectedEnabled);
                              } else if (action == 'backups') {
                                _openBackupProxiesDialog();
                              } else if (action == 'probe') {
                                _triggerAutoSwitch();
                              }
                            },
                            itemBuilder: (ctx) => [
                              PopupMenuItem<String>(
                                value: 'toggle',
                                height: 48,
                                child: Row(
                                  children: [
                                    Icon(
                                      _autoSwitchEnabled
                                          ? Icons.check_box_rounded
                                          : Icons.check_box_outline_blank_rounded,
                                      size: 16,
                                      color: _autoSwitchEnabled
                                          ? tokens.cobalt
                                          : tokens.textMuted,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          TText(
                                            'Auto Home/Office',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                              color: tokens.textPrimary,
                                            ),
                                          ),
                                          TText(
                                            'Office → proxy · Home → direct',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: tokens.textMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (appState.advancedMode)
                                PopupMenuItem<String>(
                                  value: 'stay',
                                  height: 50,
                                  child: Row(
                                    children: [
                                      Icon(
                                        _stayConnectedEnabled
                                            ? Icons.check_box_rounded
                                            : Icons.check_box_outline_blank_rounded,
                                        size: 16,
                                        color: _stayConnectedEnabled
                                            ? tokens.cobalt
                                            : tokens.textMuted,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            TText(
                                              'Stay connected',
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w500,
                                                color: tokens.textPrimary,
                                              ),
                                            ),
                                            TText(
                                              'Fail over to backups & return when yours recovers',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                color: tokens.textMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (appState.advancedMode && _stayConnectedEnabled)
                                PopupMenuItem<String>(
                                  value: 'backups',
                                  height: 44,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.backup_table_rounded,
                                        size: 15,
                                        color: tokens.textSecondary,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            TText(
                                              'Backup proxies…',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: tokens.textPrimary,
                                              ),
                                            ),
                                            Text(
                                              _backupMode == 'selected'
                                                  ? tl(ctx, '{count} selected').replaceAll(
                                                      '{count}',
                                                      '${_backupProxyIds.length}')
                                                  : tl(ctx, 'All saved proxies'),
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                color: tokens.textMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              if (_autoSwitchEnabled || _stayConnectedEnabled)
                                PopupMenuItem<String>(
                                  value: 'probe',
                                  height: 44,
                                  child: Row(
                                    children: [
                                      LuxIcon(
                                        LuxGlyph.refresh,
                                        size: 13.5,
                                        color: tokens.textSecondary,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            TText(
                                              'Check network now',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: tokens.textPrimary,
                                              ),
                                            ),
                                            TText(
                                              'Re-test which network you are on',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                color: tokens.textMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: (_autoSwitchEnabled || _stayConnectedEnabled)
                                    ? tokens.cobalt.withValues(alpha: 0.12)
                                    : tokens.cardBg,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: (_autoSwitchEnabled || _stayConnectedEnabled)
                                      ? tokens.cobalt.withValues(alpha: 0.4)
                                      : tokens.hairlineStrong,
                                  width: 0.75,
                                ),
                              ),
                              child: Center(
                                child: LuxIcon(
                                  LuxGlyph.swap,
                                  size: 14,
                                  color: (_autoSwitchEnabled || _stayConnectedEnabled)
                                      ? tokens.cobalt
                                      : tokens.textSecondary,
                                ),
                              ),
                            ),
                          ),
                  ),
                  if ((_autoSwitchEnabled || _stayConnectedEnabled) &&
                      _autoSwitchState.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    _AutoSwitchChip(
                      state: _autoSwitchState,
                      proxyName: _autoSwitchProxyName,
                      preferredName: _autoSwitchPreferredName,
                    ),
                  ],
                  const SizedBox(width: 6),
                  _isDetecting
                      ? SizedBox(
                          width: compactDetect ? 74 : 114,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                compactDetect
                                    ? '${(_detectProgress * 100).round()}%'
                                    : '${tl(context, 'Detecting')} ${(_detectProgress * 100).round()}%',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: tokens.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: _detectProgress,
                                  minHeight: 2.5,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Tooltip(
                          message: tl(context, 'Detect Proxy'),
                          child: SizedBox(
                            height: 34,
                            width: compactDetect ? 34 : null,
                            child: OutlinedButton(
                              key: const Key('proxies-detect-button'),
                              onPressed: _detectProxies,
                              style: OutlinedButton.styleFrom(
                                backgroundColor: tokens.cardBg,
                                foregroundColor: tokens.textPrimary,
                                padding: compactDetect
                                    ? EdgeInsets.zero
                                    : const EdgeInsets.symmetric(horizontal: 11),
                                minimumSize: const Size(0, 34),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                side: BorderSide(
                                  color: tokens.hairlineStrong,
                                  width: 0.75,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(9),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  LuxIcon(
                                    LuxGlyph.radar,
                                    size: 13.5,
                                    color: tokens.textSecondary,
                                  ),
                                  if (!compactDetect) ...[
                                    const SizedBox(width: 6),
                                    const TText(
                                      'Detect Proxy',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                ],
              );
            },
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
                : LuxScrollEdgeFade(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
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
                          onSelect: handleSelectProxy,
                          selectedId: proxyListGroup.selectedId,
                          subscriptionList: subscriptionList,
                          coreManager: widget.coreManager,
                          onTestStatusChanged: (id, status) {
                            if (!mounted) return;
                            setState(() => _testStatuses[id] = status);
                          },
                          selectedController: _selectedItemController,
                          onCredentialsSaved: refreshData,
                          onPeekPassword: widget.onPeekPassword,
                        );
                      },
                    ),
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

  Future<void> _checkCertForProxy(
    DetectedProxy proxy,
    _ProxyCredentials creds, {
    CertCheckResult? precheckedCert,
  }) async {
    try {
      final result = precheckedCert ??
          await widget.coreManager.checkCert(
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

      // Pre-check: if already installed in system root store, do not show prompt / mark healthy
      if (result.pem.isNotEmpty) {
        final thumbprint = extractCertThumbprintSha1(result.pem);
        if (thumbprint != null && await isCertInSystemStore(thumbprint: thumbprint)) {
          return;
        }
      }

      if (!mounted) return;

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
                  'system root certificate store.',
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
                await _installCert(result, proxyHost: proxy.host);
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

  Future<void> _installCert(CertCheckResult cert, {String? proxyHost}) async {
    try {
      final host = proxyHost ?? cert.subject;
      await trustProxyCertificate(proxyHost: host, pem: cert.pem);
      try {
        await widget.coreManager.installCert(cert.pem);
      } catch (_) {}

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: TText('Certificate installed and trusted. Proxy is ready.'),
        ),
      );
    } on CertTrustException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Certificate install failed: $e')),
      );
    }
  }

  Future<_ProxyCredentials?> _promptCredentials(DetectedProxy proxy) async {
    return showDialog<_ProxyCredentials>(
      context: context,
      builder: (_) => _CredentialsDialog(proxy: proxy),
    );
  }

  String _formatDetectionSource(BuildContext ctx, String source) {
    switch (source) {
      case 'wpad-dns':
        return tl(ctx, 'WPAD DNS');
      case 'dhcp-252':
        return tl(ctx, 'DHCP Option 252');
      case 'os-pac':
      case 'saved-pac':
        return tl(ctx, 'System PAC configuration');
      case 'wpad-probe':
        return tl(ctx, 'WPAD auto-discovery');
      case 'os-manual':
        return tl(ctx, 'System proxy settings');
      case 'env':
        return tl(ctx, 'Environment variables');
      case 'lan-probe':
        return tl(ctx, 'Local network scan');
      default:
        return source;
    }
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

      if (result.proxies.isEmpty && !result.hasPac) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.message.isNotEmpty
                  ? result.message
                  : tl(context, 'No proxies or PAC scripts detected on this network'),
            ),
          ),
        );
        return;
      }

      // Build display candidates: if only a PAC URL was returned, create a PAC-only entry.
      final pacOptions = result.effectivePacUrls;
      final defaultPacUrl =
          pacOptions.isNotEmpty ? pacOptions.first.url : result.pacUrl;
      final candidates = result.proxies.isNotEmpty
          ? List<DetectedProxy>.from(result.proxies)
          : <DetectedProxy>[
              DetectedProxy(
                host: '',
                port: '',
                type: 'http',
                pacUrl: defaultPacUrl,
                pacOnly: true,
              ),
            ];
      final fixedCandidates = candidates.where((p) => !p.isPacOnly).toList();
      final bool isPurePacResult = fixedCandidates.isEmpty && result.hasPac;

      // Selection state for the confirmation dialog
      bool attachPac = result.hasPac;
      bool usePacOnly = isPurePacResult;
      String selectedPacUrl = defaultPacUrl;
      final selectedIndices = <int>{if (fixedCandidates.isNotEmpty) 0};

      // Step 1: Show detected proxies / PAC script and let user confirm selection
      final selection = await showDialog<_DetectedProxySelection>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            final tokens = LuxTokens.of(ctx);
            final activePacOption = pacOptions.cast<DetectedPacOption?>().firstWhere(
                  (o) => o!.url == selectedPacUrl,
                  orElse: () => pacOptions.isNotEmpty ? pacOptions.first : null,
                );
            final headerSource = activePacOption != null && activePacOption.source.isNotEmpty
                ? activePacOption.source
                : result.source;
            final sourceLabel = _formatDetectionSource(ctx, headerSource);
            final selectedCount = usePacOnly ? 1 : selectedIndices.length;
            final canAdd = usePacOnly ? selectedPacUrl.isNotEmpty : selectedIndices.isNotEmpty;

            Widget pacKindPill(bool isDynamic) {
              final accent = isDynamic ? tokens.emerald : tokens.textSecondary;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isDynamic
                      ? tokens.emerald.withValues(alpha: 0.14)
                      : tokens.subtlePillBg,
                  borderRadius: BorderRadius.circular(4),
                  border: isDynamic
                      ? Border.all(color: tokens.emerald.withValues(alpha: 0.35))
                      : null,
                ),
                child: Text(
                  isDynamic ? tl(ctx, 'Dynamic DNS') : tl(ctx, 'Static IP'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              );
            }

            return AlertDialog(
              titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
              actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              title: Row(
                children: [
                  Icon(Icons.radar_rounded, size: 18, color: tokens.cobalt),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TText(
                      isPurePacResult ? 'Detected PAC Script' : 'Detected Proxies',
                    ),
                  ),
                  if (sourceLabel.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: tokens.cobalt.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: tokens.cobalt.withValues(alpha: 0.35)),
                      ),
                      child: Text(
                        sourceLabel,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: tokens.cobalt,
                        ),
                      ),
                    ),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 440),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (pacOptions.isNotEmpty) ...[
                          Material(
                            color: Theme.of(ctx).brightness == Brightness.dark
                                ? const Color(0xFF0E131D)
                                : const Color(0xFFF8FAFC),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(color: tokens.hairline),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.alt_route_rounded,
                                          size: 16, color: tokens.cobalt),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: TText(
                                          'PAC Script',
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: tokens.textPrimary,
                                          ),
                                        ),
                                      ),
                                      if (pacOptions.length == 1) ...[
                                        pacKindPill(pacOptions.first.isDynamic),
                                        const SizedBox(width: 6),
                                      ],
                                      if (result.pacRuleCount > 0)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: tokens.subtlePillBg,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            '${result.pacRuleCount} ${tl(ctx, 'PAC rules')}',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: tokens.textSecondary,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  if (pacOptions.length == 1)
                                    SelectableText(
                                      selectedPacUrl,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontFamily: 'monospace',
                                        color: tokens.textSecondary,
                                      ),
                                    )
                                  else
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: pacOptions.map((opt) {
                                        final isSelected = opt.url == selectedPacUrl;
                                        final optSrc = _formatDetectionSource(ctx, opt.source);
                                        return InkWell(
                                          borderRadius: BorderRadius.circular(6),
                                          onTap: () => setDialogState(
                                            () => selectedPacUrl = opt.url,
                                          ),
                                          child: Container(
                                            margin: const EdgeInsets.only(bottom: 4),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 6),
                                            decoration: BoxDecoration(
                                              color: isSelected
                                                  ? tokens.cobalt.withValues(alpha: 0.10)
                                                  : Colors.transparent,
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(
                                                color: isSelected
                                                    ? tokens.cobalt.withValues(alpha: 0.45)
                                                    : tokens.hairline,
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  isSelected
                                                      ? Icons.radio_button_checked
                                                      : Icons.radio_button_unchecked,
                                                  size: 16,
                                                  color: isSelected
                                                      ? tokens.cobalt
                                                      : tokens.textMuted,
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                        opt.url,
                                                        style: TextStyle(
                                                          fontSize: 11.5,
                                                          fontFamily: 'monospace',
                                                          fontWeight: isSelected
                                                              ? FontWeight.w600
                                                              : FontWeight.w400,
                                                          color: tokens.textPrimary,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                      if (optSrc.isNotEmpty)
                                                        Text(
                                                          optSrc,
                                                          style: TextStyle(
                                                            fontSize: 10,
                                                            color: tokens.textMuted,
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                pacKindPill(opt.isDynamic),
                                              ],
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  if (fixedCandidates.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    CheckboxListTile(
                                      value: attachPac,
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity: ListTileControlAffinity.leading,
                                      visualDensity: VisualDensity.compact,
                                      title: TText(
                                        'Attach PAC script',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: tokens.textPrimary,
                                        ),
                                      ),
                                      onChanged: usePacOnly
                                          ? null
                                          : (v) => setDialogState(() => attachPac = v ?? true),
                                    ),
                                    CheckboxListTile(
                                      value: usePacOnly,
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity: ListTileControlAffinity.leading,
                                      visualDensity: VisualDensity.compact,
                                      title: TText(
                                        'PAC-only (dynamic routing)',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: tokens.textPrimary,
                                        ),
                                      ),
                                      onChanged: (v) => setDialogState(() {
                                        usePacOnly = v ?? false;
                                        if (usePacOnly) attachPac = true;
                                      }),
                                    ),
                                  ] else ...[
                                    const SizedBox(height: 4),
                                    TText(
                                      'PAC-only: this PAC picks the upstream proxy per site.',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: tokens.textMuted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (fixedCandidates.isNotEmpty) const SizedBox(height: 10),
                        ],
                        if (fixedCandidates.isNotEmpty)
                          Opacity(
                            opacity: usePacOnly ? 0.45 : 1.0,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(fixedCandidates.length, (i) {
                                final p = fixedCandidates[i];
                                final checked = !usePacOnly && selectedIndices.contains(i);
                                final protoLabel = p.type.toUpperCase();
                                final subtitle = p.type == 'socks5'
                                    ? tl(ctx, 'SOCKS5 Proxy')
                                    : tl(ctx, 'HTTP Proxy');

                                return CheckboxListTile(
                                  value: checked,
                                  dense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                                  controlAffinity: ListTileControlAffinity.leading,
                                  onChanged: usePacOnly
                                      ? null
                                      : (v) => setDialogState(() {
                                            if (v == true) {
                                              selectedIndices.add(i);
                                            } else {
                                              selectedIndices.remove(i);
                                            }
                                          }),
                                  title: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: tokens.subtlePillBg,
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: tokens.hairline),
                                        ),
                                        child: Text(
                                          protoLabel,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: tokens.textSecondary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          p.displayName,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  subtitle: Text(
                                    subtitle,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: tokens.textMuted,
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const TText('Cancel'),
                ),
                FilledButton(
                  onPressed: canAdd
                      ? () {
                          final chosen = usePacOnly
                              ? <DetectedProxy>[
                                  DetectedProxy(
                                    host: '',
                                    port: '',
                                    type: 'http',
                                    pacUrl: selectedPacUrl,
                                    pacOnly: true,
                                  ),
                                ]
                              : (selectedIndices.toList()..sort())
                                  .map((idx) => fixedCandidates[idx])
                                  .toList();
                          Navigator.pop(
                            ctx,
                            _DetectedProxySelection(
                              proxies: chosen,
                              attachPac: attachPac || usePacOnly,
                              pacUrl: selectedPacUrl,
                            ),
                          );
                        }
                      : null,
                  child: Text(
                    usePacOnly
                        ? tl(ctx, 'Add PAC Proxy')
                        : selectedCount == 1
                            ? tl(ctx, 'Add Proxy')
                            : tl(ctx, 'Add {count} Proxies')
                                .replaceAll('{count}', '$selectedCount'),
                  ),
                ),
              ],
            );
          },
        ),
      );

      if (selection == null || selection.proxies.isEmpty) return;

      // Step 2: Prompt for credentials with retry on auth failure
      final firstProxy = selection.proxies.first;
      // If an HTTP host is available (even when saving PAC-only from a PAC that
      // returned hosts), probe it to verify credentials and read any bump cert
      // organization name.
      DetectedProxy? certProbeProxy;
      if (!firstProxy.isPacOnly && firstProxy.type == 'http') {
        certProbeProxy = firstProxy;
      } else {
        for (final p in fixedCandidates) {
          if (p.type == 'http' && p.host.isNotEmpty) {
            certProbeProxy = p;
            break;
          }
        }
      }

      _ProxyCredentials? creds;
      CertCheckResult? certResult;

      while (true) {
        creds = await _promptCredentials(firstProxy);
        if (creds == null) return;

        // Step 3: Validate credentials & inspect SSL bump cert when an HTTP host exists
        if (certProbeProxy == null) break;
        final probePort = int.tryParse(certProbeProxy.port) ?? 8080;
        try {
          certResult = await widget.coreManager.checkCert(
            server: certProbeProxy.host,
            port: probePort,
            username: creds.username,
            password: creds.password,
          );
        } catch (_) {
          // Network/timeout error - proceed without cert info
          break;
        }

        // Check if auth failed (407 in response body)
        if (certResult.error.isNotEmpty) {
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

      // Step 4: Derive proxy name from bump cert issuer when intercepted;
      // otherwise default to sequential "Proxy 1", "Proxy 2", ... (never raw IP/host).
      final existingNameList = proxyListGroup.allProxies.map((p) => p.name).toList();
      final suggestedName = suggestDetectedProxyName(
        certResult: certResult,
        existingNames: existingNameList,
      );

      // Widget may have unmounted during the credential prompt / cert check
      // above (desktop window close or hot-restart). Guard before using context.
      if (!mounted) return;

      // Step 5: Let user confirm or override the name (no duplicates)
      final existingNamesLower =
          existingNameList.map((n) => n.trim().toLowerCase()).toSet();
      final confirmedName = await showDialog<String>(
        context: context,
        builder: (_) => _NameProxyDialog(
          initialName: suggestedName,
          existingNamesLower: existingNamesLower,
        ),
      );
      if (confirmedName == null || confirmedName.isEmpty) return;

      // Step 6: Add each selected proxy with deduplicated names and PAC URL preserved
      final takenLower = Set<String>.from(existingNamesLower);
      final addedNames = <String>[];
      for (final p in selection.proxies) {
        final proxyName = uniqueProxyName(confirmedName, takenLower);
        addedNames.add(proxyName);
        final effectivePacUrl = p.isPacOnly
            ? (selection.pacUrl.isNotEmpty ? selection.pacUrl : p.pacUrl)
            : (selection.attachPac
                ? (selection.pacUrl.isNotEmpty ? selection.pacUrl : p.pacUrl)
                : '');

        await widget.coreManager.addProxy({
          'name': proxyName,
          'type': p.type,
          'server': p.isPacOnly ? '' : p.host.trim(),
          'port': p.isPacOnly ? 0 : (int.tryParse(p.port) ?? 8080),
          if (effectivePacUrl.isNotEmpty) 'pacUrl': effectivePacUrl,
          if (creds.username.trim().isNotEmpty) 'username': creds.username.trim(),
          if (creds.password.isNotEmpty) 'password': creds.password,
          if (creds.passwordMode.isNotEmpty) 'passwordMode': creds.passwordMode,
          if (creds.passwordMode == 'timed' && creds.ttlMinutes > 0)
            'passwordTTLMinutes': creds.ttlMinutes,
        });
      }
      await refreshProxyList();
      if (mounted) {
        final summary = addedNames.length == 1
            ? tl(context, 'Added proxy "{name}"')
                .replaceAll('{name}', addedNames.first)
            : tl(context, 'Added {count} proxies')
                .replaceAll('{count}', '${addedNames.length}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(summary)),
        );
        // Show SSL interception info if detected
        if (certResult != null && certResult.intercepted && certProbeProxy != null) {
          _checkCertForProxy(certProbeProxy, creds, precheckedCert: certResult);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tl(context, 'Detection failed')}: $e'),
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

/// Extracts a human-friendly organization/CA name from an SSL bump cert's
/// issuer DN (`O=` preferred, then `CN=`), rejecting empty, generic, or raw
/// IP/host values. Works for BOTH untrusted MITM certs (`intercepted == true`)
/// and already-trusted corporate bump CAs (`bumpDetected == true`).
/// Returns `null` when no bump cert or usable name is available.
String? _extractBumpCertName(CertCheckResult? certResult) {
  if (certResult == null || !certResult.hasBumpCert) return null;
  final issuer = certResult.issuer.trim();
  if (issuer.isEmpty) return null;

  String? extractAttr(String key) {
    // Match `O=...` or `CN=...` at start or after comma/whitespace, handling
    // RFC 2253 escaped commas (`\,`) and optional surrounding quotes.
    final re = RegExp('(?:^|[,;\\s])$key=((?:\\\\.|[^,;])+)', caseSensitive: false);
    final match = re.firstMatch(issuer);
    if (match == null) return null;
    var val = match.group(1)!.trim();
    val = val.replaceAll(r'\,', ',').replaceAll(r'\"', '"');
    if (val.length >= 2 && val.startsWith('"') && val.endsWith('"')) {
      val = val.substring(1, val.length - 1).trim();
    }
    return val;
  }

  bool isUsableName(String? raw) {
    if (raw == null) return false;
    final v = raw.trim();
    if (v.isEmpty) return false;
    final lower = v.toLowerCase();
    const generic = {
      'localhost',
      'unknown',
      'default',
      'none',
      'n/a',
      'untitled',
      'proxy',
    };
    if (generic.contains(lower)) return false;
    // Reject bare IPv4 addresses or IPv6 / host:port literals.
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?$').hasMatch(v)) return false;
    if (v.contains(':')) return false;
    return true;
  }

  final org = extractAttr('O');
  if (isUsableName(org)) return org!.trim();

  final cn = extractAttr('CN');
  if (isUsableName(cn)) return cn!.trim();

  return null;
}

/// Returns the next unused sequential default proxy name (`Proxy 1`, `Proxy 2`,
/// ...) compared case-insensitively against [existingNames].
String nextDefaultProxyName(Iterable<String> existingNames) {
  final taken = existingNames.map((n) => n.trim().toLowerCase()).toSet();
  var index = 1;
  while (taken.contains('proxy $index')) {
    index++;
  }
  return 'Proxy $index';
}

/// Deduplicates [base] against [takenLower] (updating [takenLower] in place).
/// If [base] already ends with a number (e.g. `Proxy 1`), increments the number
/// (`Proxy 2`, `Proxy 3`, ...) instead of appending ` 2` (`Proxy 1 2`).
String uniqueProxyName(String base, Set<String> takenLower) {
  final trimmed = base.trim();
  final candidate = trimmed.isEmpty ? 'Proxy 1' : trimmed;
  if (takenLower.add(candidate.toLowerCase())) {
    return candidate;
  }

  final numbered = RegExp(r'^(.*?\s)(\d+)$').firstMatch(candidate);
  if (numbered != null) {
    final prefix = numbered.group(1)!;
    var num = int.tryParse(numbered.group(2)!) ?? 1;
    while (true) {
      num++;
      final next = '$prefix$num';
      if (takenLower.add(next.toLowerCase())) return next;
    }
  }

  var suffix = 2;
  while (true) {
    final next = '$candidate $suffix';
    if (takenLower.add(next.toLowerCase())) return next;
    suffix++;
  }
}

/// Computes the default name for a newly auto-detected proxy:
/// 1. If SSL interception (bump cert) was detected and exposes a usable `O=` or
///    `CN=`, uses that name (deduplicated against [existingNames]).
/// 2. Otherwise falls back to sequential `Proxy 1`, `Proxy 2`, ... — never the
///    raw server IP or hostname.
String suggestDetectedProxyName({
  CertCheckResult? certResult,
  required Iterable<String> existingNames,
}) {
  final certName = _extractBumpCertName(certResult);
  if (certName != null) {
    final taken = existingNames.map((n) => n.trim().toLowerCase()).toSet();
    return uniqueProxyName(certName, taken);
  }
  return nextDefaultProxyName(existingNames);
}

class _DetectedProxySelection {
  final List<DetectedProxy> proxies;
  final bool attachPac;
  final String pacUrl;

  const _DetectedProxySelection({
    required this.proxies,
    required this.attachPac,
    required this.pacUrl,
  });
}

class _CredentialsDialog extends StatefulWidget {
  final DetectedProxy proxy;
  const _CredentialsDialog({required this.proxy});

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _ttlCtrl = TextEditingController(text: '60');
  String _passwordMode = 'persistent';
  int _ttlMinutes = 60;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _ttlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(
      context,
      _ProxyCredentials(
        username: _usernameCtrl.text,
        password: _passwordCtrl.text,
        passwordMode: _passwordMode,
        ttlMinutes: _ttlMinutes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final subtitle = widget.proxy.isPacOnly
        ? tl(context, 'PAC-only (dynamic routing)')
        : widget.proxy.displayName;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: Row(
        children: [
          Icon(Icons.key_rounded, size: 18, color: tokens.cobalt),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TText(
                  widget.proxy.isPacOnly
                      ? 'Credentials for PAC proxy'
                      : 'Credentials',
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: luxMonoStyle(
                    fontSize: 11.5,
                    color: tokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _usernameCtrl,
              autofocus: true,
              style: TextStyle(fontSize: 13, color: tokens.textPrimary),
              decoration: InputDecoration(
                labelText: tl(context, 'Username'),
                prefixIcon: Icon(Icons.person_outline_rounded,
                    size: 16, color: tokens.textMuted),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              style: TextStyle(fontSize: 13, color: tokens.textPrimary),
              decoration: InputDecoration(
                labelText: tl(context, 'Password'),
                prefixIcon: Icon(Icons.lock_outline_rounded,
                    size: 16, color: tokens.textMuted),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _passwordMode,
              isExpanded: true,
              dropdownColor: Theme.of(context).dialogTheme.backgroundColor,
              style: TextStyle(fontSize: 13, color: tokens.textPrimary),
              decoration: InputDecoration(
                labelText: tl(context, 'Password type'),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'persistent',
                  child: TText('Persistent (saved)', overflow: TextOverflow.ellipsis),
                ),
                DropdownMenuItem(
                  value: 'timed',
                  child: TText('Timed (expires)', overflow: TextOverflow.ellipsis),
                ),
                DropdownMenuItem(
                  value: 'one-time',
                  child: TText('One-time (cleared after use)', overflow: TextOverflow.ellipsis),
                ),
              ],
              onChanged: (v) => setState(() => _passwordMode = v!),
            ),
            if (_passwordMode == 'timed') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _ttlCtrl,
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 13, color: tokens.textPrimary),
                decoration: InputDecoration(
                  labelText: tl(context, 'Expires after (minutes)'),
                ),
                onChanged: (v) => _ttlMinutes = int.tryParse(v) ?? 60,
              ),
            ],
            const SizedBox(height: 10),
            TText(
              'Leave empty if the proxy does not require authentication.',
              style: TextStyle(fontSize: 11.5, color: tokens.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const TText('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const TText('Continue'),
        ),
      ],
    );
  }
}

class _NameProxyDialog extends StatefulWidget {
  final String initialName;
  final Set<String> existingNamesLower;
  const _NameProxyDialog({
    required this.initialName,
    required this.existingNamesLower,
  });

  @override
  State<_NameProxyDialog> createState() => _NameProxyDialogState();
}

class _NameProxyDialogState extends State<_NameProxyDialog> {
  late final TextEditingController _nameCtrl;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _validate(String v) {
    final trimmed = v.trim().toLowerCase();
    setState(() {
      if (trimmed.isEmpty) {
        _nameError = tl(context, 'Name cannot be empty');
      } else if (widget.existingNamesLower.contains(trimmed)) {
        _nameError = tl(context, 'A proxy with this name already exists');
      } else {
        _nameError = null;
      }
    });
  }

  void _submit() {
    final trimmed = _nameCtrl.text.trim();
    if (_nameError == null && trimmed.isNotEmpty) {
      Navigator.pop(context, trimmed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      title: Row(
        children: [
          Icon(Icons.label_outline_rounded, size: 18, color: tokens.cobalt),
          const SizedBox(width: 8),
          const Expanded(child: TText('Name this proxy')),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _nameCtrl,
          style: TextStyle(fontSize: 13, color: tokens.textPrimary),
          decoration: InputDecoration(
            labelText: tl(context, 'Proxy name'),
            hintText: tl(context, 'e.g. Office, School, Home'),
            errorText: _nameError,
          ),
          autofocus: true,
          onChanged: _validate,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const TText('Cancel'),
        ),
        FilledButton(
          onPressed: _nameError == null && _nameCtrl.text.trim().isNotEmpty
              ? _submit
              : null,
          child: const TText('Add'),
        ),
      ],
    );
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

/// Self-explanatory status chip shown next to the Auto Home/Office button.
class _AutoSwitchChip extends StatelessWidget {
  final String state;
  final String proxyName;
  final String preferredName;
  const _AutoSwitchChip({
    required this.state,
    required this.proxyName,
    this.preferredName = '',
  });

  @override
  Widget build(BuildContext context) {
    final (color, icon, label, tip) = switch (state) {
      'corporate' => (
          Colors.green,
          Icons.business_rounded,
          proxyName.isNotEmpty
              ? '${tl(context, 'Office')} · $proxyName'
              : tl(context, 'Office'),
          tl(context, 'Work proxy reachable — routing through {name}')
              .replaceAll('{name}', proxyName.isNotEmpty ? proxyName : 'proxy'),
        ),
      'failover' => (
          Colors.amber.shade700,
          Icons.sync_rounded,
          proxyName.isNotEmpty
              ? '${tl(context, 'Backup')} · $proxyName'
              : tl(context, 'Backup'),
          preferredName.isNotEmpty
              ? tl(context,
                      '{preferred} unavailable — temporarily using {active}; will switch back automatically.')
                  .replaceAll('{preferred}', preferredName)
                  .replaceAll('{active}', proxyName)
              : tl(context, 'Temporarily using backup proxy; will switch back automatically.'),
        ),
      'direct' => (
          Colors.blue,
          Icons.home_outlined,
          '${tl(context, 'Home')} · ${tl(context, 'Direct')}',
          tl(context,
              'No work proxy reachable — using direct internet. Re-checking every 45s.'),
        ),
      'captive_portal' => (
          Colors.orange,
          Icons.wifi_lock_rounded,
          tl(context, 'Wi-Fi login'),
          tl(context, 'Sign in on the Wi-Fi page; Lux resumes automatically.'),
        ),
      'no_internet' => (
          Colors.red,
          Icons.signal_wifi_off_rounded,
          tl(context, 'Offline · retrying'),
          tl(context, 'No proxy reachable — retrying automatically.'),
        ),
      _ => (Colors.grey, Icons.swap_horiz, state, state),
    };
    return Tooltip(
      message: tip,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 160),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          border: Border.all(color: color.withAlpha(120)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11.5, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
