import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/error.dart';
import 'package:lux/model/app.dart';
import 'package:lux/theme.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/telemetry.dart' as telem;
import 'package:lux/util/updater.dart'
    show
        checkForUpdate,
        showUpdateConfirmDialog,
        showUpdateProgressDialog,
        startUpdate,
        updateStateNotifier,
        UpdateState,
        UpdateInfo;
import 'package:lux/widget/lux_icons.dart';
import 'package:lux/widget/lux_scroll_edge_fade.dart';
import 'package:lux/widget/setting_tiles.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';
import 'package:window_manager/window_manager.dart';

/// Single-pane Settings styled after macOS System Settings:
/// - No double sidebar — full content width with grouped hairline cards.
/// - Top sticky live search + horizontal category filter pills (`All` shows
///   every group in one smooth scroll; tapping any pill focuses that section).
/// - Updates sit right at the top of `All` so checking/installing takes 1 click.
class SettingsPage extends StatefulWidget {
  final CoreManager coreManager;
  final String dashboardUrl;
  final String? initialCategory;

  const SettingsPage({
    super.key,
    required this.coreManager,
    this.dashboardUrl = '',
    this.initialCategory,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WindowListener {
  Setting? _setting;
  bool _isReconnecting = false;
  bool _isSaving = false;
  Timer? _recoveryTimer;
  List<String> _interfaces = [];

  /// `'all'` renders every category card in one scrollable page; any other id
  /// filters to that single category.
  String _selectedCategory = 'all';
  String _query = '';
  final _searchCtrl = TextEditingController();

  telem.TelemetryLevel _telemetryLevel = telem.TelemetryLevel.off;
  String _telemetryUuid = '';
  bool _uuidCopied = false;

  bool _checkingUpdate = false;
  bool _enablingWindowsService = false;
  String _appVersion = '';
  String _pendingUpdateVersion = '';
  UpdateInfo? _cachedUpdateInfo;

  static const _categories = [
    (id: 'updates', glyph: LuxGlyph.download, label: 'Updates'),
    (id: 'general', glyph: LuxGlyph.settings, label: 'General'),
    (id: 'network', glyph: LuxGlyph.globe, label: 'Network'),
    (id: 'tun', glyph: LuxGlyph.route, label: 'TUN / Mixed'),
    (id: 'dns', glyph: LuxGlyph.shield, label: 'DNS'),
    (id: 'privacy', glyph: LuxGlyph.lock, label: 'Privacy'),
    (id: 'advanced', glyph: LuxGlyph.bolt, label: 'Advanced'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialCategory != null &&
        _categories.any((c) => c.id == widget.initialCategory)) {
      _selectedCategory = widget.initialCategory!;
    }
    windowManager.addListener(this);
    _load();
    _searchCtrl.addListener(
        () => setState(() => _query = _searchCtrl.text.trim().toLowerCase()));
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCategory != oldWidget.initialCategory &&
        widget.initialCategory != null &&
        _categories.any((c) => c.id == widget.initialCategory)) {
      setState(() => _selectedCategory = widget.initialCategory!);
    }
  }

  @override
  void onWindowFocus() {
    if (!_isSaving) _load();
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    windowManager.removeListener(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _isConnectionError(dynamic e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return true;
      }
      final errStr = e.error?.toString() ?? '';
      if (errStr.contains('SocketException') ||
          errStr.contains('Connection refused') ||
          errStr.contains('errno = 61')) {
        return true;
      }
    }
    if (e is SocketException) return true;
    final s = e.toString();
    return s.contains('Connection refused') ||
        s.contains('SocketException') ||
        s.contains('connection error');
  }

  Future<void> _load() async {
    _recoveryTimer?.cancel();
    try {
      final setting = await widget.coreManager.getSetting();
      final ifaces = await widget.coreManager.getSettingInterfaces();
      final level = await readTelemetryLevel();
      final uuid = await readOrCreateTelemetryUuid();
      final rawVersion = await getAppVersionString();
      var pending = await readPendingUpdateVersion();
      if (pending != null && pending.isNotEmpty) {
        if (!_isNewerThanCurrent(pending, rawVersion)) {
          await writePendingUpdateVersion(null);
          pending = null;
        }
      }
      if (!mounted) return;
      setState(() {
        _setting = setting;
        _interfaces = ifaces;
        _telemetryLevel = telem.telemetryLevelFromString(level);
        _telemetryUuid = uuid;
        _appVersion = rawVersion;
        _pendingUpdateVersion = pending ?? '';
        _isReconnecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_isConnectionError(e)) {
        setState(() => _isReconnecting = true);
        _attemptCoreRecoveryAndReload();
      } else {
        _notify('Could not load settings: $e', isError: true);
      }
    }
  }

  void _attemptCoreRecoveryAndReload([int attempt = 0]) {
    if (!mounted || attempt >= 5) return;
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(const Duration(seconds: 1), () async {
      if (!mounted) return;
      try {
        await widget.coreManager.ensureCoreRunning();
        final setting = await widget.coreManager.getSetting();
        final ifaces = await widget.coreManager.getSettingInterfaces();
        if (!mounted) return;
        setState(() {
          _setting = setting;
          _interfaces = ifaces;
          _isReconnecting = false;
        });
      } catch (_) {
        if (mounted) {
          _attemptCoreRecoveryAndReload(attempt + 1);
        }
      }
    });
  }

  bool _isNewerThanCurrent(String candidate, String current) {
    try {
      return Version.parse(candidate).compareTo(Version.parse(current)) > 0;
    } catch (_) {
      return candidate != current;
    }
  }

  Future<void> _save(Setting updated) async {
    setState(() => _isSaving = true);
    try {
      await widget.coreManager.saveSetting(updated);
      if (mounted) setState(() => _setting = updated);
    } catch (e) {
      if (!mounted) return;
      if (e is CoreElevationCancelledError) {
        _notify(tl(context, e.message), isError: true);
        await _load();
      } else if (_isConnectionError(e)) {
        _notify(tl(context, 'Reconnecting to Lux core...'), isError: false);
        _attemptCoreRecoveryAndReload();
      } else {
        _notify('Could not save: $e', isError: true);
        await _load();
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _notify(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: Duration(milliseconds: isError ? 4000 : 2500),
          backgroundColor: isError ? Colors.red : null,
        ),
      );
  }

  // ── Rows by category ───────────────────────────────────────────────────────

  List<SettingRow> _rowsFor(String categoryId) {
    final s = _setting!;
    final saving = _isSaving;
    final isTun = s.mode == ProxyMode.tun || s.mode == ProxyMode.mixed;

    switch (categoryId) {
      case 'updates':
        return [
          SettingRow(
            title: 'Check for Updates',
            keywords: ['version', 'upgrade', 'appcast'],
            build: (ctx) => _updateHeroRow(ctx),
          ),
          SettingRow(
            title: 'Latest updates',
            keywords: ['latest', 'insider', 'beta', 'early', 'pre-release', 'test'],
            build: (ctx) => FutureBuilder<bool>(
              future: readBetaUpdatesEnabled(),
              builder: (ctx, snap) {
                final isLatest = snap.data ?? false;
                return switchTile(
                  title: 'Latest updates',
                  subtitle: isLatest
                      ? 'Latest updates active. You receive the newest builds early, plus all stable releases.'
                      : 'Get the latest builds as soon as they are ready, before the regular stable release.',
                  value: isLatest,
                  onChanged: (v) async {
                    final statusMsg = v
                        ? tl(context, 'Latest updates enabled')
                        : tl(context, 'Latest updates disabled');
                    final upToDateMsg = tl(context, 'You are up to date');
                    setState(() => _checkingUpdate = true);
                    try {
                      await writeBetaUpdatesEnabled(v);
                      await clearLastUpdateCheckAt();
                      _notify(statusMsg);
                      await _load();
                      final info = await checkForUpdate();
                      _cachedUpdateInfo = info;
                      if (!mounted) return;
                      if (info != null && info.hasUpdate) {
                        await writePendingUpdateVersion(info.latestVersion);
                        if (!mounted) return;
                        setState(() {
                          _pendingUpdateVersion = info.latestVersion;
                          _checkingUpdate = false;
                        });
                        await showUpdateConfirmDialog(context, info);
                      } else {
                        await writePendingUpdateVersion(null);
                        if (!mounted) return;
                        setState(() {
                          _pendingUpdateVersion = '';
                          _checkingUpdate = false;
                        });
                        _notify(upToDateMsg);
                      }
                    } catch (e) {
                      if (mounted) {
                        _notify('Update check failed: $e', isError: true);
                      }
                    } finally {
                      if (mounted) setState(() => _checkingUpdate = false);
                    }
                  },
                );
              },
            ),
          ),
        ];

      case 'general':
        return [
          SettingRow(
            title: 'Theme',
            keywords: ['dark', 'light', 'appearance', 'obsidian', 'porcelain'],
            build: (ctx) => _themeTile(ctx),
          ),
          SettingRow(
            title: 'Language',
            keywords: ['idioma', 'locale', 'translation', 'portuguese', 'i18n'],
            build: (ctx) => _languageTile(ctx),
          ),
          SettingRow(
            title: 'Auto Launch',
            keywords: ['startup', 'login', 'boot'],
            build: (_) => switchTile(
              title: 'Auto Launch',
              subtitle: 'Start Lux when you log in',
              value: s.autoLaunch,
              onChanged: saving ? null : (v) => _save(s.copyWith(autoLaunch: v)),
            ),
          ),
          SettingRow(
            title: 'Auto Connect',
            keywords: ['connect', 'startup'],
            build: (_) => switchTile(
              title: 'Auto Connect',
              subtitle: 'Connect proxy when Lux opens',
              value: s.autoConnect,
              onChanged:
                  saving ? null : (v) => _save(s.copyWith(autoConnect: v)),
            ),
          ),
          SettingRow(
            title: 'Sensitive Info Mode',
            keywords: ['privacy', 'hide', 'ip', 'screenshot'],
            build: (_) => switchTile(
              title: 'Sensitive Info Mode',
              subtitle: 'Hide IP addresses and proxy names in UI',
              value: s.sensitiveInfoMode ?? false,
              onChanged: saving
                  ? null
                  : (v) => _save(s.copyWith(sensitiveInfoMode: v)),
            ),
          ),
          if (widget.coreManager.isWindows)
            SettingRow(
              title: 'Background Service',
              keywords: [
                'windows',
                'service',
                'admin',
                'uac',
                'uwp',
                'store',
                'icloud',
                'limited',
                'mixed',
                'tun',
                'elevation',
              ],
              build: (ctx) => _windowsServiceTile(ctx),
            ),
        ];

      case 'network':
        return [
          SettingRow(
            title: 'Proxy Mode',
            keywords: ['tun', 'system', 'mixed'],
            build: (ctx) => segmentedTile<ProxyMode>(
              context: ctx,
              title: 'Proxy Mode',
              subtitle: _proxyModeExplanation(s.mode),
              value: s.mode,
              options: const [ProxyMode.system, ProxyMode.mixed, ProxyMode.tun],
              label: getModeLabel,
              onChanged: saving ? null : (v) => _save(s.copyWith(mode: v)),
            ),
          ),
          SettingRow(
            title: 'Auto-switch proxy',
            keywords: [
              'auto',
              'switch',
              'home',
              'office',
              'network',
              'detect',
              'bypass',
              'captive',
              'portal',
              'airport',
              'hotel',
            ],
            build: (ctx) => FutureBuilder<bool>(
              future: readAutoSwitchEnabled(),
              builder: (ctx, snap) => switchTile(
                title: 'Auto-switch proxy',
                subtitle:
                    'When the selected proxy stops working, Lux tries other '
                    'proxies, then direct. Captive Wi-Fi sign-in assist always '
                    'works automatically.',
                value: snap.data ?? false,
                onChanged: (v) async {
                  final enabledMsg = tl(context, 'Auto-switch enabled');
                  final disabledMsg = tl(context, 'Auto-switch disabled');
                  await writeAutoSwitchEnabled(v);
                  await widget.coreManager.setNetSwitchEnabled(v);
                  if (v) {
                    final lastId = await readLastUserProxyId();
                    await widget.coreManager.syncNetSwitchConfig(lastId);
                  }
                  if (!mounted) return;
                  _notify(v ? enabledMsg : disabledMsg);
                  setState(() {});
                },
              ),
            ),
          ),
          SettingRow(
            title: 'Default Interface',
            keywords: ['en0', 'wifi', 'ethernet', 'adapter'],
            build: (_) => dropdownTile<String>(
              title: 'Default Interface',
              value: s.defaultInterface,
              options: ['', ..._interfaces],
              label: (v) => v.isEmpty ? 'Auto' : v,
              onChanged: saving
                  ? null
                  : (v) => _save(s.copyWith(defaultInterface: v)),
            ),
          ),
          SettingRow(
            title: 'Local Server Port',
            keywords: ['1090', 'listen', 'http proxy'],
            build: (_) => numberTile(
              title: 'Local Server Port',
              value: s.localServerPort,
              subtitle: 'Port Lux listens on for proxy traffic',
              onChanged: saving
                  ? null
                  : (v) => _save(s.copyWith(localServerPort: v)),
            ),
          ),
          SettingRow(
            title: 'Allow LAN',
            keywords: ['share', 'network', 'other devices'],
            build: (_) => switchTile(
              title: 'Allow LAN',
              subtitle: 'Allow other devices to connect via LAN',
              value: s.allowLan,
              onChanged: saving ? null : (v) => _save(s.copyWith(allowLan: v)),
            ),
          ),
        ];

      case 'tun':
        if (!isTun) {
          return [
            SettingRow(
              title: 'TUN settings unavailable',
              build: (ctx) {
                final tokens = LuxTokens.of(ctx);
                return Padding(
                  padding: const EdgeInsets.all(14),
                  child: TText(
                    'These settings apply to TUN and Mixed mode. Switch Proxy '
                    'Mode to Mixed or TUN to enable them.',
                    style: TextStyle(fontSize: 12, color: tokens.textMuted),
                  ),
                );
              },
            ),
          ];
        }
        return [
          SettingRow(
            title: 'Block QUIC',
            keywords: ['http3', 'udp', '443', 'youtube'],
            build: (_) => switchTile(
              title: 'Block QUIC',
              subtitle: 'Disable HTTP/3 (fixes YouTube and some sites)',
              value: s.blockQuic ?? false,
              onChanged: saving ? null : (v) => _save(s.copyWith(blockQuic: v)),
            ),
          ),
          SettingRow(
            title: 'Find Process',
            keywords: ['process rules', 'app', 'connections'],
            build: (_) => switchTile(
              title: 'Find Process',
              subtitle:
                  'Identify which app made each connection (shows in Connections)',
              value: s.shouldFindProcess ?? false,
              onChanged: saving
                  ? null
                  : (v) => _save(s.copyWith(shouldFindProcess: v)),
            ),
          ),
          SettingRow(
            title: 'Bypass CIDRs',
            keywords: [
              'bypass',
              'cidr',
              'subnets',
              'ip',
              'lan',
              'route',
              'exclude',
              'tun'
            ],
            build: (ctx) => _bypassCidrsTile(ctx, s),
          ),
        ];

      case 'dns':
        return [
          SettingRow(
            title: 'Fake IP',
            keywords: ['dns', 'performance', 'resolve'],
            build: (_) => switchTile(
              title: 'Fake IP',
              subtitle: 'Forward DNS queries to proxy for better performance',
              value: s.fakeIp ?? false,
              onChanged: saving ? null : (v) => _save(s.copyWith(fakeIp: v)),
            ),
          ),
          SettingRow(
            title: 'Disable DNS Cache',
            keywords: ['cache', 'stale', 'resolve'],
            build: (_) => switchTile(
              title: 'Disable DNS Cache',
              subtitle: 'Always get latest DNS responses',
              value: s.disableDnsCache ?? false,
              onChanged: saving
                  ? null
                  : (v) => _save(s.copyWith(disableDnsCache: v)),
            ),
          ),
          SettingRow(
            title: 'Hijack DNS',
            keywords: ['system dns', 'networksetup', 'intercept'],
            build: (_) => switchTile(
              title: 'Hijack DNS',
              subtitle: 'Modify system DNS to route through Lux',
              value: s.hijackDns,
              onChanged: saving ? null : (v) => _save(s.copyWith(hijackDns: v)),
            ),
          ),
        ];

      case 'privacy':
        return [
          SettingRow(
            title: 'Anonymous usage data',
            keywords: ['telemetry', 'analytics', 'reporting', 'privacy'],
            build: (ctx) => _telemetryTile(ctx),
          ),
          SettingRow(
            title: 'Device ID',
            keywords: ['uuid', 'telemetry', 'support'],
            build: (ctx) => copyableTile(
              context: ctx,
              title: 'Device ID',
              value: _telemetryUuid.isEmpty ? 'not generated' : _telemetryUuid,
              subtitle: 'Random, not linked to any account. Quote it in reports.',
              copied: _uuidCopied,
              onCopy: () async {
                await Clipboard.setData(ClipboardData(text: _telemetryUuid));
                if (!mounted) return;
                setState(() => _uuidCopied = true);
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) setState(() => _uuidCopied = false);
                });
              },
            ),
          ),
        ];

      case 'advanced':
        return [
          SettingRow(
            title: 'Enable Auto Mode',
            keywords: ['fallback', 'url-test', 'latency'],
            build: (_) => switchTile(
              title: 'Enable Auto Mode',
              subtitle:
                  'Core-level latency probing (url-test / fallback) across proxies',
              value: s.autoModeEnabled,
              onChanged: saving
                  ? null
                  : (v) => _save(s.copyWith(autoModeEnabled: v)),
            ),
          ),
          if (s.autoModeEnabled)
            SettingRow(
              title: 'Auto Mode Type',
              keywords: ['fallback', 'url-test'],
              build: (_) => dropdownTile<String>(
                title: 'Auto Mode Type',
                value: s.autoModeType.isEmpty ? 'fallback' : s.autoModeType,
                options: const ['fallback', 'url-test'],
                label: (v) =>
                    v == 'fallback' ? 'Fallback' : 'URL Test (fastest)',
                onChanged: saving
                    ? null
                    : (v) => _save(s.copyWith(autoModeType: v)),
              ),
            ),
          if (s.autoModeEnabled)
            SettingRow(
              title: 'Test URL',
              keywords: ['latency', 'probe'],
              build: (_) => textFieldTile(
                title: 'Test URL',
                value: s.autoModeUrl,
                hint: 'https://google.com',
                onChanged: saving
                    ? null
                    : (v) => _save(s.copyWith(autoModeUrl: v)),
              ),
            ),
          SettingRow(
            title: 'Configuration file',
            keywords: [
              'config',
              'config.json',
              'import',
              'export',
              'edit',
              'backup',
              'restore'
            ],
            build: (ctx) => _configFileRow(ctx),
          ),
          SettingRow(
            title: 'Update Server',
            keywords: ['appcast', 'url', 'custom', 'updates'],
            build: (ctx) => _appcastTile(ctx),
          ),
          if (widget.dashboardUrl.isNotEmpty)
            SettingRow(
              title: 'Web Dashboard',
              keywords: ['web', 'browser', 'dashboard', 'debug', 'advanced'],
              build: (ctx) => actionTile(
                context: ctx,
                title: 'Web Dashboard',
                subtitle: 'Open the built-in browser dashboard (advanced)',
                buttonLabel: 'Open',
                glyph: LuxGlyph.externalLink,
                onPressed: () => launchUrl(Uri.parse(widget.dashboardUrl)),
              ),
            ),
        ];
    }
    return [];
  }

  String _proxyModeExplanation(ProxyMode mode) {
    switch (mode) {
      case ProxyMode.system:
        return 'Sets system HTTP/HTTPS proxy — browsers & standard apps.';
      case ProxyMode.mixed:
        return 'System proxy plus TUN capture for all apps (recommended).';
      case ProxyMode.tun:
        return 'Virtual network interface capturing all system traffic.';
    }
  }

  Widget _updateHeroRow(BuildContext context) {
    final tokens = LuxTokens.of(context);
    return ValueListenableBuilder<UpdateState>(
      valueListenable: updateStateNotifier,
      builder: (ctx, updateState, _) {
        final isDownloading = updateState.isDownloading;
        final hasPending = _pendingUpdateVersion.isNotEmpty ||
            (updateState.updateInfo != null &&
                updateState.updateInfo!.hasUpdate);
        final targetVersion = _pendingUpdateVersion.isNotEmpty
            ? _pendingUpdateVersion
            : (updateState.updateInfo?.latestVersion ?? '');

        if (hasPending || isDownloading) {
          final progress = updateState.progress;
          final pct = progress != null ? (progress * 100).toInt() : null;
          final statusText = updateState.status;

          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            title: Row(children: [
              TText(
                isDownloading ? 'Updating...' : 'Update available',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: tokens.amber.withValues(alpha: 0.14),
                  border: Border.all(
                      color: tokens.amber.withValues(alpha: 0.45), width: 0.75),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  targetVersion,
                  style: luxMonoStyle(
                    fontSize: 10.5,
                    color: tokens.amber,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ]),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 2),
                Text(
                  '$_appVersion → $targetVersion',
                  style: luxMonoStyle(fontSize: 11, color: tokens.textMuted),
                ),
                if (isDownloading) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (progress == null || progress < 0.02)
                          ? null
                          : progress,
                      minHeight: 4,
                      backgroundColor: tokens.subtlePillBg,
                      valueColor: AlwaysStoppedAnimation<Color>(tokens.amber),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusText.isNotEmpty
                        ? statusText
                        : (pct != null ? 'Downloading… $pct%' : 'Downloading…'),
                    style: TextStyle(fontSize: 11, color: tokens.amber),
                  ),
                ],
              ],
            ),
            trailing: _checkingUpdate
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.8, color: tokens.cobalt),
                  )
                : isDownloading
                    ? FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: tokens.amber,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          minimumSize: const Size(0, 29),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(7)),
                        ),
                        onPressed: () {
                          if (updateState.updateInfo != null) {
                            showUpdateProgressDialog(
                                context, updateState.updateInfo!);
                          }
                        },
                        child: Text(
                          pct != null ? '$pct%' : tl(context, 'Updating...'),
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      )
                    : FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: tokens.amber,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          minimumSize: const Size(0, 29),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(7)),
                        ),
                        onPressed: () async {
                          final upToDateMsg = tl(context, 'You are up to date');
                          UpdateInfo? info = _cachedUpdateInfo;
                          if (info == null ||
                              !info.hasUpdate ||
                              info.latestVersion != targetVersion) {
                            setState(() => _checkingUpdate = true);
                            try {
                              info = await checkForUpdate();
                              _cachedUpdateInfo = info;
                            } finally {
                              if (mounted) {
                                setState(() => _checkingUpdate = false);
                              }
                            }
                          }
                          if (!mounted) return;
                          if (info == null || !info.hasUpdate) {
                            await writePendingUpdateVersion(null);
                            if (!mounted) return;
                            setState(() => _pendingUpdateVersion = '');
                            _notify(upToDateMsg);
                            return;
                          }
                          final updateInfo = info;
                          await writePendingUpdateVersion(
                              updateInfo.latestVersion);
                          if (!mounted || !context.mounted) return;
                          setState(() =>
                              _pendingUpdateVersion = updateInfo.latestVersion);
                          await startUpdate(context, updateInfo,
                              showDialog: true);
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            LuxIcon(LuxGlyph.download,
                                size: 12.5, color: Colors.white),
                            SizedBox(width: 5),
                            TText('Update', style: TextStyle(fontSize: 11.5)),
                          ],
                        ),
                      ),
          );
        }

        return actionTile(
          context: ctx,
          title: 'Check for Updates',
          subtitle: 'Current version $_appVersion',
          buttonLabel: 'Check',
          glyph: LuxGlyph.refresh,
          busy: _checkingUpdate,
          onPressed: _checkingUpdate ? null : _runUpdateCheck,
        );
      },
    );
  }

  Widget _configFileRow(BuildContext context) {
    final tokens = LuxTokens.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      title: TText(
        'Configuration file',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w400,
          color: tokens.textPrimary,
        ),
      ),
      subtitle: TText(
        'Export a backup, import one, or edit config.json directly.',
        style: TextStyle(fontSize: 11, color: tokens.textMuted),
      ),
      trailing: Wrap(
        spacing: 6,
        children: [
          OutlinedButton(
            onPressed: _exportConfig,
            style: OutlinedButton.styleFrom(
              foregroundColor: tokens.textPrimary,
              side: BorderSide(color: tokens.hairlineStrong, width: 0.75),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 29),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LuxIcon(LuxGlyph.upload, size: 12, color: tokens.textSecondary),
                const SizedBox(width: 5),
                const TText('Export', style: TextStyle(fontSize: 11.5)),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: _editConfig,
            style: OutlinedButton.styleFrom(
              foregroundColor: tokens.textPrimary,
              side: BorderSide(color: tokens.hairlineStrong, width: 0.75),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 29),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LuxIcon(LuxGlyph.edit, size: 12, color: tokens.textSecondary),
                const SizedBox(width: 5),
                const TText('Edit', style: TextStyle(fontSize: 11.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Config import / export / edit ──────────────────────────────────────────

  Future<void> _exportConfig() async {
    try {
      final content = await widget.coreManager.exportConfig();
      final dir = await getApplicationSupportDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/config-backup-$stamp.json');
      await file.writeAsString(content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Config exported to ${file.path}'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Copy path',
            onPressed: () => Clipboard.setData(ClipboardData(text: file.path)),
          ),
        ),
      );
    } catch (e) {
      _notify('Export failed: $e', isError: true);
    }
  }

  Future<void> _editConfig() async {
    String content;
    try {
      content = await widget.coreManager.exportConfig();
    } catch (e) {
      _notify('Could not load config: $e', isError: true);
      return;
    }
    if (!mounted) return;
    final ctrl = TextEditingController(text: content);
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          LuxIcon(LuxGlyph.edit, size: 17),
          SizedBox(width: 8),
          TText('Edit config.json'),
        ]),
        content: SizedBox(
          width: 560,
          height: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const TText(
                'Paste a backup here to import it, or edit and save. '
                'Invalid JSON will be rejected.',
                style: TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: luxMonoStyle(fontSize: 11),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                    isDense: true,
                  ),
                ),
              ),
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
            child: const TText('Save & Apply'),
          ),
        ],
      ),
    );

    if (save != true) return;
    try {
      jsonDecode(ctrl.text);
    } catch (e) {
      _notify('Not valid JSON — not saved.', isError: true);
      return;
    }
    try {
      await widget.coreManager.importConfig(ctrl.text);
      if (!mounted) return;
      _notify('Config applied. Restart the connection if needed.');
      Provider.of<AppStateModel>(context, listen: false).bumpProxyList();
    } catch (e) {
      final msg = e is DioException
          ? (e.response?.data is Map
              ? (e.response!.data['message'] ?? e.message)
              : e.message)
          : e.toString();
      _notify('Import rejected: $msg', isError: true);
    }
  }

  // ── Individual complex rows ────────────────────────────────────────────────

  Widget _windowsServiceTile(BuildContext context) {
    final tokens = LuxTokens.of(context);
    final limited =
        context.select<AppStateModel, bool>((m) => m.windowsLimitedMode);
    final statusColor = limited ? tokens.amber : tokens.emerald;

    return ListTile(
      key: const Key('settings_windows_service_tile'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      title: Row(
        children: [
          TText(
            'Background Service',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: tokens.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.14),
              border: Border.all(
                  color: statusColor.withValues(alpha: 0.45), width: 0.75),
              borderRadius: BorderRadius.circular(5),
            ),
            child: TText(
              limited ? 'Limited' : 'Active',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                color: statusColor,
              ),
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TText(
          limited
              ? 'Limited mode: browsers and standard desktop apps work normally, but Microsoft Store / UWP apps (such as iCloud and Microsoft Store) and Mixed / TUN modes require one-time admin setup.'
              : 'Active — Microsoft Store / UWP apps and Mixed / TUN modes are enabled with no repeat UAC prompts.',
          style: TextStyle(fontSize: 11, color: tokens.textMuted),
        ),
      ),
      trailing: limited
          ? FilledButton(
              key: const Key('settings_windows_service_enable_btn'),
              onPressed: _enablingWindowsService
                  ? null
                  : () async {
                      setState(() => _enablingWindowsService = true);
                      try {
                        final ok =
                            await widget.coreManager.enableWindowsService();
                        if (!mounted) return;
                        _notify(
                          tl(
                            this.context,
                            ok
                                ? 'Background service enabled. Full functionality is now active.'
                                : 'Admin setup cancelled. Continuing in limited System mode.',
                          ),
                          isError: !ok,
                        );
                        if (ok) await _load();
                      } catch (e) {
                        if (!mounted) return;
                        _notify('$e', isError: true);
                      } finally {
                        if (mounted) {
                          setState(() => _enablingWindowsService = false);
                        }
                      }
                    },
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                minimumSize: const Size(0, 29),
                textStyle: const TextStyle(fontSize: 11.5),
              ),
              child: _enablingWindowsService
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const TText('Enable now'),
            )
          : LuxIcon(LuxGlyph.check, size: 16, color: tokens.emerald),
    );
  }

  Widget _bypassCidrsTile(BuildContext context, Setting s) {
    final tokens = LuxTokens.of(context);
    final cidrs = s.bypassCidrs;
    final saving = _isSaving;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        TText(
                          'Bypass CIDRs',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w400,
                            color: tokens.textPrimary,
                          ),
                        ),
                        if (cidrs.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: tokens.subtlePillBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: tokens.hairline, width: 0.75),
                            ),
                            child: Text(
                              '${cidrs.length}',
                              style: luxMonoStyle(
                                fontSize: 10,
                                color: tokens.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    TText(
                      'Subnets routed outside the TUN tunnel (DIRECT). Proxy IPs are auto-bypassed.',
                      style: TextStyle(fontSize: 11, color: tokens.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: saving ? null : () => _showAddBypassCidrDialog(s),
                style: OutlinedButton.styleFrom(
                  foregroundColor: tokens.textPrimary,
                  side: BorderSide(color: tokens.hairlineStrong, width: 0.75),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 29),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LuxIcon(LuxGlyph.plus,
                        size: 12, color: tokens.textSecondary),
                    const SizedBox(width: 5),
                    const TText('Add Subnet', style: TextStyle(fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (cidrs.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: tokens.subtlePillBg,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: tokens.hairline, width: 0.75),
              ),
              child: Row(
                children: [
                  LuxIcon(LuxGlyph.alertCircle,
                      size: 13, color: tokens.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TText(
                      'No custom bypass CIDRs configured. Upstream proxies and DIRECT rules are automatically excluded.',
                      style: TextStyle(fontSize: 11, color: tokens.textMuted),
                    ),
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: cidrs.map((cidr) {
                return Container(
                  padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
                  decoration: BoxDecoration(
                    color: tokens.subtlePillBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: tokens.hairline, width: 0.75),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        cidr,
                        style: luxMonoStyle(
                            fontSize: 11, color: tokens.textPrimary),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: saving
                            ? null
                            : () {
                                final updated = List<String>.from(cidrs)
                                  ..remove(cidr);
                                _save(s.copyWith(bypassCidrs: updated));
                              },
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: LuxIcon(LuxGlyph.close,
                              size: 11, color: tokens.textMuted),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Future<void> _showAddBypassCidrDialog(Setting s) async {
    final ctrl = TextEditingController();
    String? errorText;

    const presets = [
      '192.168.0.0/16',
      '10.0.0.0/8',
      '172.16.0.0/12',
      '100.64.0.0/10'
    ];

    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              LuxIcon(LuxGlyph.route, size: 18),
              SizedBox(width: 8),
              TText('Add Bypass CIDR'),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TText(
                  'Enter an IPv4 CIDR subnet (e.g. 192.168.0.0/16) or single IP address to exclude from the TUN interface:',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: luxMonoStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: 'e.g. 192.168.1.0/24 or 10.0.0.1',
                    errorText: errorText,
                    border: const OutlineInputBorder(),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    final val = ctrl.text.trim();
                    final validated = _validateAndNormalizeCidr(val);
                    if (validated == null) {
                      setDialogState(
                          () => errorText = 'Invalid IPv4 CIDR or IP address');
                    } else if (s.bypassCidrs.contains(validated)) {
                      setDialogState(() => errorText = 'CIDR already added');
                    } else {
                      Navigator.pop(ctx, validated);
                    }
                  },
                ),
                const SizedBox(height: 12),
                const TText('Presets:',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: presets.map((p) {
                    final already = s.bypassCidrs.contains(p);
                    return ActionChip(
                      label: Text(p, style: luxMonoStyle(fontSize: 10.5)),
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onPressed: already
                          ? null
                          : () {
                              ctrl.text = p;
                              setDialogState(() => errorText = null);
                            },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const TText('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final val = ctrl.text.trim();
                final validated = _validateAndNormalizeCidr(val);
                if (validated == null) {
                  setDialogState(
                      () => errorText = 'Invalid IPv4 CIDR or IP address');
                } else if (s.bypassCidrs.contains(validated)) {
                  setDialogState(() => errorText = 'CIDR already added');
                } else {
                  Navigator.pop(ctx, validated);
                }
              },
              child: const TText('Add'),
            ),
          ],
        ),
      ),
    );

    if (added != null && added.isNotEmpty) {
      final updated = List<String>.from(s.bypassCidrs)..add(added);
      await _save(s.copyWith(bypassCidrs: updated));
      _notify('Added bypass CIDR: $added');
    }
  }

  String? _validateAndNormalizeCidr(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;

    final parts = text.split('/');
    if (parts.length > 2) return null;

    final ip = parts[0];
    final ipRegex = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
    final match = ipRegex.firstMatch(ip);
    if (match == null) return null;

    for (var i = 1; i <= 4; i++) {
      final octet = int.tryParse(match.group(i)!);
      if (octet == null || octet < 0 || octet > 255) return null;
    }

    if (parts.length == 2) {
      final prefix = int.tryParse(parts[1]);
      if (prefix == null || prefix < 0 || prefix > 32) return null;
      return '$ip/$prefix';
    }

    return '$ip/32';
  }

  Widget _languageTile(BuildContext context) {
    final current =
        context.select<AppStateModel, String>((m) => m.locale.languageCode);
    final options = ['system', 'en', ...TranslationCache.availableLanguages];
    return dropdownTile<String>(
      title: 'Language',
      value: options.contains(current) ? current : 'system',
      options: options,
      label: (v) {
        switch (v) {
          case 'system':
            return 'System';
          case 'en':
            return 'English';
          case 'pt':
            return 'Português';
          case 'es':
            return 'Español';
          case 'it':
            return 'Italiano';
          case 'fil':
            return 'Filipino';
          case 'zh':
            return '中文';
          default:
            return v;
        }
      },
      subtitle: 'Untranslated text stays in English',
      onChanged: (v) async {
        await setLocale(v);
        if (!mounted) return;
        // ignore: use_build_context_synchronously
        Provider.of<AppStateModel>(context, listen: false)
            .updateLocale(Locale(v == 'system' ? 'en' : v));
      },
    );
  }

  Widget _themeTile(BuildContext context) {
    final mode = context.select<AppStateModel, ThemeMode>((m) => m.theme);
    return segmentedTile<ThemeMode>(
      context: context,
      title: 'Theme',
      subtitle: 'Porcelain Light, Obsidian Dark, or follow system',
      value: mode,
      options: const [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
      label: (m) => switch (m) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      },
      onChanged: (v) async {
        await writeTheme(v);
        if (!mounted) return;
        // ignore: use_build_context_synchronously
        Provider.of<AppStateModel>(context, listen: false).updateTheme(v);
      },
    );
  }

  Widget _telemetryTile(BuildContext context) {
    final tokens = LuxTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        dropdownTile<telem.TelemetryLevel>(
          title: 'Anonymous usage data',
          value: _telemetryLevel,
          options: const [
            telem.TelemetryLevel.off,
            telem.TelemetryLevel.ops,
            telem.TelemetryLevel.full,
          ],
          label: (l) => switch (l) {
            telem.TelemetryLevel.off => 'Off',
            telem.TelemetryLevel.ops => 'Errors only',
            telem.TelemetryLevel.full => 'Full',
          },
          onChanged: (v) async {
            await writeTelemetryLevel(telem.telemetryLevelToString(v));
            telem.setTelemetryLevel(v);
            if (mounted) setState(() => _telemetryLevel = v);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: TText(
            telem.telemetryLevelDescription(_telemetryLevel),
            style: TextStyle(fontSize: 11, color: tokens.textMuted),
          ),
        ),
        if (!telem.telemetryConfigured)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(
              'No reporting endpoint is configured in this build, so nothing is '
              'sent regardless of this setting.',
              style: TextStyle(fontSize: 11, color: tokens.amber),
            ),
          ),
      ],
    );
  }

  Widget _appcastTile(BuildContext context) {
    return FutureBuilder<String?>(
      future: readCustomAppcastUrl(),
      builder: (ctx, snap) => textFieldTile(
        title: 'Update Server',
        value: snap.data ?? '',
        hint: 'leave empty for the default',
        subtitle: 'Appcast URL describing the newest build',
        onChanged: (v) async {
          final savedMsg = tl(context, 'Update server saved');
          await writeCustomAppcastUrl(v.trim().isEmpty ? null : v.trim());
          if (!mounted) return;
          _notify(savedMsg);
          setState(() {});
        },
      ),
    );
  }

  Future<void> _runUpdateCheck() async {
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
        _notify(upToDateMsg);
      } else {
        await writePendingUpdateVersion(info.latestVersion);
        if (!mounted) return;
        setState(() => _pendingUpdateVersion = info.latestVersion);
        await showUpdateConfirmDialog(context, info);
      }
    } catch (e) {
      _notify('Update check failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  // ── Layout ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tokens = LuxTokens.of(context);
    if (_setting == null) {
      if (_isReconnecting) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: tokens.cobalt),
                ),
                const SizedBox(height: 18),
                TText(
                  'Reconnecting to Lux core...',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: tokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                TText(
                  'The core process is starting up or reconnecting.',
                  style: TextStyle(fontSize: 12.5, color: tokens.textMuted),
                ),
                const SizedBox(height: 18),
                OutlinedButton(
                  onPressed: _load,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LuxIcon(LuxGlyph.refresh,
                          size: 13.5, color: tokens.textPrimary),
                      const SizedBox(width: 6),
                      const TText('Retry'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    final searching = _query.isNotEmpty;

    return Column(
      children: [
        if (_isReconnecting)
          Container(
            color: tokens.amber.withValues(alpha: 0.14),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: tokens.amber),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: TText(
                    'Reconnecting to Lux core...',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _load,
                  child: const TText('Retry'),
                ),
              ],
            ),
          ),
        _topFilterBar(tokens),
        Container(height: 0.75, color: tokens.hairline),
        Expanded(
          child: searching ? _searchResults(tokens) : _groupedSettingsList(),
        ),
      ],
    );
  }

  Widget _topFilterBar(LuxTokens tokens) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    key: const Key('settings-search-field'),
                    controller: _searchCtrl,
                    textAlignVertical: TextAlignVertical.center,
                    style: TextStyle(fontSize: 12, color: tokens.textPrimary),
                    decoration: InputDecoration(
                      hintText: tl(context, 'Search settings'),
                      hintStyle:
                          TextStyle(fontSize: 12, color: tokens.textMuted),
                      prefixIcon: Center(
                        child: LuxIcon(
                          LuxGlyph.search,
                          key: const Key('settings-search-icon'),
                          size: 13.5,
                          color: tokens.textMuted,
                        ),
                      ),
                      prefixIconConstraints:
                          const BoxConstraints.tightFor(width: 32, height: 32),
                      suffixIconConstraints:
                          const BoxConstraints.tightFor(width: 30, height: 32),
                      isDense: true,
                      filled: true,
                      fillColor: tokens.cardBg,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 0),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: tokens.hairline, width: 0.75),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: tokens.cobalt, width: 1.0),
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                  width: 30, height: 32),
                              icon: LuxIcon(LuxGlyph.close,
                                  size: 12, color: tokens.textMuted),
                              onPressed: () => _searchCtrl.clear(),
                            ),
                    ),
                  ),
                ),
              ),
              if (_isSaving)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: tokens.cobalt,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Horizontal category filter pills — replaces the cramped 2nd sidebar.
          LuxScrollEdgeFade(
            axis: Axis.horizontal,
            startFade: 14,
            endFade: 24,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterPill(
                    tokens: tokens,
                    id: 'all',
                    label: 'All',
                  ),
                  for (final c in _categories) ...[
                    const SizedBox(width: 5),
                    _filterPill(
                      tokens: tokens,
                      id: c.id,
                      label: c.label,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterPill({
    required LuxTokens tokens,
    required String id,
    required String label,
  }) {
    final active = _selectedCategory == id && _query.isEmpty;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: Key('settings-filter-$id'),
        borderRadius: BorderRadius.circular(7),
        onTap: () {
          if (_query.isNotEmpty) _searchCtrl.clear();
          setState(() => _selectedCategory = id);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: active
                ? tokens.cobalt.withValues(alpha: 0.14)
                : tokens.subtlePillBg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: active
                  ? tokens.cobalt.withValues(alpha: 0.45)
                  : tokens.hairline,
              width: 0.75,
            ),
          ),
          child: TText(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              color: active ? tokens.cobalt : tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchResults(LuxTokens tokens) {
    final sections = <Widget>[];
    for (final c in _categories) {
      final hits = _rowsFor(c.id).where((r) => r.matches(_query)).toList();
      if (hits.isEmpty) continue;
      sections.add(sectionHeader(context, c.label, glyph: c.glyph));
      sections.add(settingCard(
          context, hits.map((r) => r.build(context)).toList()));
    }

    if (sections.isEmpty) {
      return Center(
        child: TText(
          'No settings match "$_query"',
          style: TextStyle(fontSize: 12, color: tokens.textMuted),
        ),
      );
    }
    return LuxScrollEdgeFade(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: sections,
      ),
    );
  }

  Widget _groupedSettingsList() {
    final visibleCats = _selectedCategory == 'all'
        ? _categories
        : _categories.where((c) => c.id == _selectedCategory).toList();

    return LuxScrollEdgeFade(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
        children: [
          for (final c in visibleCats) ...[
            sectionHeader(context, c.label, glyph: c.glyph),
            settingCard(
              context,
              _rowsFor(c.id).map((r) => r.build(context)).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

String getModeLabel(ProxyMode m) {
  switch (m) {
    case ProxyMode.tun:
      return 'TUN';
    case ProxyMode.system:
      return 'System';
    case ProxyMode.mixed:
      return 'Mixed';
  }
}
