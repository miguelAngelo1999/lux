import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/telemetry.dart' as telem;
import 'package:lux/util/updater.dart' show checkForUpdate, showUpdateDialog;
import 'package:lux/widget/setting_tiles.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

/// Settings with a category sidebar and live search.
///
/// Rows are declared as data (a [SettingRow] carrying a title, search keywords
/// and a builder) rather than inlined into one long build method. Search then
/// filters across every category without threading a query through nested
/// widgets, and a category is just a list of rows.
///
/// Load balancing and SSL/MITM are deliberately absent: both were unreliable and
/// have been dropped rather than carried over.
class SettingsPage extends StatefulWidget {
  final CoreManager coreManager;
  const SettingsPage({super.key, required this.coreManager});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WindowListener {
  Setting? _setting;
  bool _isLoading = true;
  bool _isSaving = false;
  List<String> _interfaces = [];

  int _selected = 0;
  String _query = '';
  final _searchCtrl = TextEditingController();

  telem.TelemetryLevel _telemetryLevel = telem.TelemetryLevel.off;
  String _telemetryUuid = '';
  bool _uuidCopied = false;

  bool _checkingUpdate = false;
  String _appVersion = '';

  static const _categories = [
    (id: 'general', icon: Icons.tune, label: 'General'),
    (id: 'network', icon: Icons.wifi, label: 'Network'),
    (id: 'dns', icon: Icons.dns, label: 'DNS'),
    (id: 'tun', icon: Icons.hub, label: 'TUN / Mixed'),
    (id: 'privacy', icon: Icons.privacy_tip_outlined, label: 'Privacy'),
    (id: 'updates', icon: Icons.system_update_alt, label: 'Updates'),
    (id: 'advanced', icon: Icons.settings_suggest, label: 'Advanced'),
  ];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _load();
    _searchCtrl.addListener(
        () => setState(() => _query = _searchCtrl.text.trim().toLowerCase()));
  }

  @override
  void onWindowFocus() {
    // Reloading mid-edit would discard what the user is typing.
    if (!_isSaving) _load();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final setting = await widget.coreManager.getSetting();
      final ifaces = await widget.coreManager.getSettingInterfaces();
      final level = await readTelemetryLevel();
      final uuid = await readOrCreateTelemetryUuid();
      final version = await getAppVersionString();
      if (!mounted) return;
      setState(() {
        _setting = setting;
        _interfaces = ifaces;
        _telemetryLevel = telem.telemetryLevelFromString(level);
        _telemetryUuid = uuid;
        _appVersion = version;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _notify('Could not load settings: $e', isError: true);
    }
  }

  Future<void> _save(Setting updated) async {
    setState(() => _isSaving = true);
    try {
      await widget.coreManager.saveSetting(updated);
      if (mounted) setState(() => _setting = updated);
    } catch (e) {
      _notify('Could not save: $e', isError: true);
      // Re-read so the UI shows what is actually stored rather than the value we
      // failed to write.
      await _load();
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _notify(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
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
      case 'general':
        return [
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
          SettingRow(
            title: 'Language',
            keywords: ['idioma', 'locale', 'translation', 'portuguese', 'i18n'],
            build: (ctx) => _languageTile(ctx),
          ),
          SettingRow(
            title: 'Theme',
            keywords: ['dark', 'light', 'appearance'],
            build: (ctx) => _themeTile(ctx),
          ),
        ];

      case 'network':
        return [
          SettingRow(
            title: 'Proxy Mode',
            keywords: ['tun', 'system', 'mixed'],
            build: (_) => dropdownTile<ProxyMode>(
              title: 'Proxy Mode',
              value: s.mode,
              options: const [ProxyMode.system, ProxyMode.tun, ProxyMode.mixed],
              label: getModeLabel,
              onChanged: saving ? null : (v) => _save(s.copyWith(mode: v)),
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

      case 'tun':
        if (!isTun) {
          return [
            SettingRow(
              title: 'TUN settings unavailable',
              build: (ctx) => const Padding(
                padding: EdgeInsets.all(12),
                child: TText(
                  'These settings apply to TUN and Mixed mode. Change Proxy Mode '
                  'under Network to enable them.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
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

      case 'updates':
        return [
          SettingRow(
            title: 'Check for Updates',
            keywords: ['version', 'upgrade', 'appcast'],
            build: (ctx) => actionTile(
              context: ctx,
              title: 'Check for Updates',
              subtitle: 'Current version $_appVersion',
              buttonLabel: 'Check',
              icon: Icons.refresh,
              busy: _checkingUpdate,
              onPressed: _checkingUpdate ? null : _runUpdateCheck,
            ),
          ),
          SettingRow(
            title: 'Update Server',
            keywords: ['appcast', 'url', 'custom'],
            build: (ctx) => _appcastTile(ctx),
          ),
        ];

      case 'advanced':
        return [
          SettingRow(
            title: 'Enable Auto Mode',
            keywords: ['fallback', 'url-test', 'latency'],
            build: (_) => switchTile(
              title: 'Enable Auto Mode',
              subtitle: 'Automatically test proxies and select the best one',
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
        ];
    }
    return [];
  }

  // ── Individual complex rows ────────────────────────────────────────────────

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
    return dropdownTile<ThemeMode>(
      title: 'Theme',
      value: mode,
      options: const [ThemeMode.system, ThemeMode.light, ThemeMode.dark],
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TText(
            telem.telemetryLevelDescription(_telemetryLevel),
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
        if (!telem.telemetryConfigured)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'No reporting endpoint is configured in this build, so nothing is '
              'sent regardless of this setting.',
              style: TextStyle(fontSize: 11, color: Colors.orange),
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
          await writeCustomAppcastUrl(v.trim().isEmpty ? null : v.trim());
          _notify('Update server saved');
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Future<void> _runUpdateCheck() async {
    setState(() => _checkingUpdate = true);
    try {
      final info = await checkForUpdate();
      if (!mounted) return;
      if (info == null || !info.hasUpdate) {
        _notify('You are up to date');
      } else {
        await showUpdateDialog(context, info);
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
    if (_isLoading || _setting == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final searching = _query.isNotEmpty;

    return Column(
      children: [
        _searchBar(),
        const Divider(height: 1),
        Expanded(
          child: searching ? _searchResults() : _sidebarAndContent(),
        ),
      ],
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search settings',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 14),
                          onPressed: () => _searchCtrl.clear(),
                        ),
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }

  /// Search spans every category, so a setting is findable without knowing which
  /// section holds it. Each hit is labelled with its category.
  Widget _searchResults() {
    final results = <Widget>[];
    for (final c in _categories) {
      final hits = _rowsFor(c.id).where((r) => r.matches(_query)).toList();
      if (hits.isEmpty) continue;
      results.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Icon(c.icon, size: 13, color: Colors.grey),
            const SizedBox(width: 5),
            TText(c.label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ));
      results.addAll(hits.map((r) => r.build(context)));
    }

    if (results.isEmpty) {
      return Center(
        child: TText('No settings match "$_query"',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return ListView(
        padding: const EdgeInsets.only(bottom: 24), children: results);
  }

  Widget _sidebarAndContent() {
    final category = _categories[_selected];
    final rows = _rowsFor(category.id);

    return Row(
      children: [
        SizedBox(
          width: 168,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: _categories.length,
            itemBuilder: (ctx, i) {
              final c = _categories[i];
              final active = i == _selected;
              return InkWell(
                onTap: () => setState(() => _selected = i),
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  color: active
                      ? Theme.of(ctx).colorScheme.primary.withValues(alpha: 0.12)
                      : null,
                  child: Row(
                    children: [
                      Icon(c.icon,
                          size: 15,
                          color: active
                              ? Theme.of(ctx).colorScheme.primary
                              : null),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TText(
                          c.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: active ? FontWeight.w600 : null,
                            color: active
                                ? Theme.of(ctx).colorScheme.primary
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            children: [
              sectionHeader(context, category.label),
              ...rows.map((r) => r.build(context)),
            ],
          ),
        ),
      ],
    );
  }
}

String getModeLabel(ProxyMode m) {
  switch (m) {
    case ProxyMode.tun:
      return 'TUN';
    case ProxyMode.system:
      return 'System';
    default:
      return 'Mixed';
  }
}
