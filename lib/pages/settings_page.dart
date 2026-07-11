import 'dart:convert';
import 'dart:io';
import 'package:lux/util/cert_installer.dart';
import 'package:lux/util/network_reset.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/util/updater.dart' show checkForUpdate, showUpdateDialog;
import 'package:lux/util/utils.dart' hide checkForUpdate;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:lux/util/t_text.dart';

// Search index entry: searchable text + the widget to render
typedef _SettingEntry = ({String text, Widget widget});
// A category group for the settings index
typedef _SettingGroup = ({String category, List<_SettingEntry> items});

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
  // SSL inspection state
  SslBumpStatus? _sslStatus;
  bool _sslChecking = false;
  bool _sslInstalling = false;
  InstallResult? _installResult;
  // Network tools state
  String? _networkToolStatus;
  // MITM CA install state
  bool _mitmCaInstalling = false;

  List<String> _interfaces = [];

  // DNS server lists (loaded from raw config)
  List<String> _dnsRemote = [];
  List<String> _dnsLocal = [];
  List<String> _dnsBoost = [];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _load();
  }

  @override
  void onWindowFocus() => _load();

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
      // Load raw DNS server lists from backend
      List<String> remote = [];
      List<String> local = [];
      List<String> boost = [];
      try {
        final rawRes = await widget.coreManager.dio.get(
            'http://${widget.coreManager.baseUrl}/setting');
        final rawSetting = rawRes.data['setting'] as Map<String, dynamic>? ?? {};
        final dns = rawSetting['dns'] as Map<String, dynamic>? ?? {};
        final server = dns['server'] as Map<String, dynamic>? ?? {};
        remote = List<String>.from(server['remote'] as List? ?? []);
        local = List<String>.from(server['local'] as List? ?? []);
        boost = List<String>.from(server['boost'] as List? ?? []);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _setting = setting;
          _interfaces = ifaces;
          _dnsRemote = remote;
          _dnsLocal = local;
          _dnsBoost = boost;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _save(Setting updated) async {
    // On Windows, switching to TUN/Mixed requires elevation.
    // If lux isn't already elevated, restart via the LuxApp scheduled task.
    if (Platform.isWindows &&
        (updated.mode == ProxyMode.tun || updated.mode == ProxyMode.mixed) &&
        _setting?.mode == ProxyMode.system) {
      final isElevated = await _checkElevated();
      if (!isElevated) {
        await _restartElevated(updated);
        return;
      }
    }

    setState(() => _isSaving = true);

    // Show a snack bar if switching proxy mode (can take a few seconds)
    final oldMode = _setting?.mode;
    final newMode = updated.mode;
    final isModeSwitch = oldMode != null && oldMode != newMode;
    if (isModeSwitch && mounted) {
      final label = getModeLabel(newMode);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          const SizedBox(width: 12),
          Text('Switching to $label mode…'),
        ]),
        duration: const Duration(seconds: 15),
      ));
    }

    try {
      await widget.coreManager.saveSetting(updated);
      if (mounted) setState(() => _setting = updated);
      // If mode switched away from TUN/Mixed, jump away from DNS/TUN categories
      final newIsTun = updated.mode == ProxyMode.tun || updated.mode == ProxyMode.mixed;
      if (!newIsTun && (_selectedCategory == 2 || _selectedCategory == 3)) {
        setState(() => _selectedCategory = 1); // jump to Network
      }
      if (isModeSwitch && mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Switched to ${getModeLabel(newMode)} mode'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Returns true if lux.exe is currently running with admin privileges.
  Future<bool> _checkElevated() async {
    try {
      final r = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '([Security.Principal.WindowsPrincipal]'
            '[Security.Principal.WindowsIdentity]::GetCurrent())'
            '.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
      ]);
      return r.stdout.toString().trim().toLowerCase() == 'true';
    } catch (_) {
      return false;
    }
  }

  /// Save the new mode to config then restart lux elevated via the LuxApp task.
  Future<void> _restartElevated(Setting updated) async {
    if (!mounted) return;

    // Check if LuxApp task exists (registered by installer)
    final taskCheck = await Process.run(
        'schtasks', ['/query', '/tn', 'LuxApp'], runInShell: false);
    final hasTask = taskCheck.exitCode == 0;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.admin_panel_settings, size: 20),
          SizedBox(width: 8),
          TText('Elevation required'),
        ]),
        content: Text(hasTask
            ? 'TUN/Mixed mode requires admin privileges.\n\n'
                'Lux will restart automatically with elevation — '
                'no UAC prompt needed.'
            : 'TUN/Mixed mode requires admin privileges.\n\n'
                'Lux will restart. You will see a UAC prompt.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: TText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: TText('Restart & Apply'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Save the mode to config first so it takes effect on restart
    try {
      await widget.coreManager.saveSetting(updated);
    } catch (_) {}

    // Restart lux elevated
    if (hasTask) {
      // Restart via scheduled task — no UAC
      await widget.coreManager.exitCore();
      await Future.delayed(const Duration(milliseconds: 500));
      await Process.run('schtasks', ['/run', '/tn', 'LuxApp'],
          runInShell: false);
    } else {
      // No task — restart via Start-Process -Verb RunAs (UAC prompt)
      final luxExe = Platform.resolvedExecutable;
      await widget.coreManager.exitCore();
      await Future.delayed(const Duration(milliseconds: 500));
      await Process.run('powershell.exe', [
        '-noprofile',
        "Start-Process '$luxExe' -Verb RunAs",
      ], runInShell: false);
    }
    exit(0);
  }

  // ── Category model for settings navigation ──────────────────────────────────

  static const _categories = [
    (id: 'general',   icon: Icons.tune,              label: 'General'),
    (id: 'network',   icon: Icons.wifi,               label: 'Network'),
    (id: 'dns',       icon: Icons.dns,                label: 'DNS'),
    (id: 'tun',       icon: Icons.hub,                label: 'TUN / Mixed'),
    (id: 'balance',   icon: Icons.balance,            label: 'Load Balancing'),
    (id: 'ssl',       icon: Icons.security,           label: 'SSL & MITM'),
    (id: 'advanced',  icon: Icons.settings_suggest,  label: 'Advanced'),
  ];
  int _selectedCategory = 0;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _setting == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final isSearching = _searchQuery.isNotEmpty;
    final isTun = _setting!.mode == ProxyMode.tun || _setting!.mode == ProxyMode.mixed;

    return Stack(
      children: [
        Row(
          children: [
            // ── Left category sidebar ─────────────────────────────────────
            SizedBox(
              width: 160,
              child: Column(
                children: [
                  // Search bar
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _searchQuery = v.toLowerCase().trim()),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Search settings…',
                        hintStyle: const TextStyle(fontSize: 12),
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 16),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close, size: 14),
                                onPressed: () => setState(() {
                                  _searchCtrl.clear();
                                  _searchQuery = '';
                                }),
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  // Category list
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: _categories.length,
                      itemBuilder: (ctx, i) {
                        final cat = _categories[i];
                        final selected = !isSearching && _selectedCategory == i;
                        final isTunOnly = cat.id == 'dns' || cat.id == 'tun';
                        final disabled = isTunOnly && !isTun;
                        return Tooltip(
                          message: disabled ? 'Only available in TUN / Mixed mode' : '',
                          child: ListTile(
                            dense: true,
                            enabled: !disabled,
                            selected: selected,
                            selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.6),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 0),
                            leading: Icon(cat.icon, size: 16,
                                color: disabled
                                    ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)
                                    : selected
                                        ? Theme.of(context).colorScheme.primary
                                        : null),
                            title: Text(cat.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                                  color: disabled
                                      ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)
                                      : null,
                                )),
                            trailing: disabled
                                ? Icon(Icons.lock_outline, size: 12,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3))
                                : null,
                            onTap: disabled ? null : () => setState(() {
                              _selectedCategory = i;
                              _searchQuery = '';
                              _searchCtrl.clear();
                            }),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            // ── Right content area ────────────────────────────────────────
            Expanded(
              child: _buildContent(isSearching),
            ),
          ],
        ),
        if (_isSaving)
          const Positioned(
            top: 8,
            right: 8,
            child: SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  Widget _buildContent(bool isSearching) {
    final s = _setting!;
    final isTun = s.mode == ProxyMode.tun || s.mode == ProxyMode.mixed;

    // All items grouped by category.
    // Each item carries: (searchable text, widget builder).
    // searchable text = "title subtitle" lowercased for fuzzy matching.

    _SettingEntry e(String title, String subtitle, Widget w) =>
        (text: '$title $subtitle'.toLowerCase(), widget: w);

    final allGroups = <_SettingGroup>[
      (
        category: 'General',
        items: [
          e('Language', 'system english chinese locale',
              _dropdownTile<String>('Language', _currentLanguage(),
                  ['system', 'en', 'zh-CN', 'fil', 'es', 'fr', 'pt', 'ar', 'de', 'ja', 'ko'], _languageLabel, _saveLanguage)),
          e('Theme', 'dark light system appearance',
              _dropdownTile<String>('Theme', _currentTheme(),
                  ['system', 'dark', 'light'], _themeLabel, _saveTheme)),
          e('Auto Launch', 'Start Lux when you log in startup',
              _switchTile('Auto Launch', 'Start Lux when you log in',
                  s.autoLaunch, (v) => _save(s.copyWith(autoLaunch: v)))),
          e('Auto Connect', 'Connect proxy when Lux opens automatically',
              _switchTile('Auto Connect', 'Connect proxy when Lux opens',
                  s.autoConnect, (v) => _save(s.copyWith(autoConnect: v)))),
          e('Sensitive Info Mode', 'Hide IP addresses proxy names privacy',
              _switchTile('Sensitive Info Mode',
                  'Hide IP addresses and proxy names in UI',
                  s.sensitiveInfoMode ?? false,
                  (v) => _save(s.copyWith(sensitiveInfoMode: v)))),
          e('Reset Dismissed Proxies', 'wizard dismissed prompts',
              _resetDismissedProxiesTile()),
          if (Platform.isWindows)
            e('Clear Saved Proxy', 'windows saved credentials',
                _clearSavedProxyTile()),
        ],
      ),
      (
        category: 'Network',
        items: [
          e('Proxy Mode', 'system tun mixed mode traffic routing',
              _dropdownTile<ProxyMode>('Proxy Mode', s.mode,
                  [ProxyMode.system, ProxyMode.tun, ProxyMode.mixed],
                  getModeLabel, (v) => _save(s.copyWith(mode: v)))),
          e('Default Interface', 'network adapter ethernet wifi interface',
              _dropdownTile<String>(
                  'Default Interface',
                  s.defaultInterface.isEmpty ? '' : s.defaultInterface,
                  ['', ..._interfaces],
                  (v) => v.isEmpty ? 'Auto' : v,
                  (v) => _save(s.copyWith(defaultInterface: v)))),
          e('Local Server Port', 'port 1090 socks http local proxy server port number',
              _numberTile('Local Server Port', s.localServerPort,
                  (v) => _save(s.copyWith(localServerPort: v)))),
          e('Allow LAN', 'local network other devices share access',
              _switchTile('Allow LAN', 'Allow other devices to connect via LAN',
                  s.allowLan, (v) => _save(s.copyWith(allowLan: v)))),
          if (Platform.isWindows)
            e('Restore Auto-Detect Proxy on Exit',
                'windows autodetect wpad pac settings restore',
                _switchTile('Restore Auto-Detect Proxy on Exit',
                    'Re-enable Windows "Automatically detect settings" when Lux stops',
                    s.restoreAutoDetect ?? false,
                    (v) => _save(s.copyWith(restoreAutoDetect: v)))),
          e('Auto Mode Type', 'fallback url-test fastest latency automatic',
              _dropdownTile<String>('Auto Mode Type',
                  s.autoModeType.isEmpty ? 'fallback' : s.autoModeType,
                  ['fallback', 'url-test'],
                  (v) => v == 'fallback' ? 'Fallback' : 'URL Test (fastest)',
                  (v) => _save(s.copyWith(autoModeType: v)))),
          e('Enable Auto Mode', 'automatically test proxies select best one',
              _switchTile('Enable Auto Mode',
                  'Automatically test proxies and select the best one',
                  s.autoModeEnabled,
                  (v) => _save(s.copyWith(autoModeEnabled: v)))),
          if (s.autoModeEnabled)
            e('Test URL', 'auto mode connectivity check url ping',
                _textFieldTile('Test URL', s.autoModeUrl, 'https://google.com',
                    (v) => _save(s.copyWith(autoModeUrl: v)))),
        ],
      ),
      (
        category: 'DNS',
        items: [
          e('Fake IP', 'DNS forward proxy performance fakeip',
              _switchTile('Fake IP',
                  'Forward DNS queries to proxy for better performance',
                  s.fakeIp ?? false,
                  (v) => _save(s.copyWith(fakeIp: v)))),
          if (s.fakeIp != true)
            e('Remote DNS', 'Resolve foreign domains 8.8.8.8 1.1.1.1',
                _dnsListTile('Remote DNS', 'Resolve foreign domains',
                    _dnsRemote, (v) => _saveDnsList('remote', v))),
          e('Local DNS', 'Resolve domestic domains 114 dhcp system auto',
              _dnsListTile('Local DNS', 'Resolve domestic domains',
                  _dnsLocal, (v) => _saveDnsList('local', v))),
          e('Boost DNS', 'Initial bootstrap resolution dhcp system auto',
              _dnsListTile('Boost DNS', 'Initial bootstrap resolution',
                  _dnsBoost, (v) => _saveDnsList('boost', v))),
          e('Disable DNS Cache', 'always latest responses flush',
              _switchTile('Disable DNS Cache',
                  'Always get latest DNS responses',
                  s.disableDnsCache ?? false,
                  (v) => _save(s.copyWith(disableDnsCache: v)))),
          e('Hijack DNS', 'system dns modify route through lux',
              _switchTile('Hijack DNS',
                  'Modify system DNS to route through Lux',
                  s.hijackDns,
                  (v) => _save(s.copyWith(hijackDns: v)))),
        ],
      ),
      (
        category: 'TUN / Mixed',
        items: [
          e('Block QUIC', 'HTTP/3 YouTube disable fix',
              _switchTile('Block QUIC',
                  'Disable HTTP/3 (fixes YouTube and some sites)',
                  s.blockQuic ?? false,
                  (v) => _save(s.copyWith(blockQuic: v)))),
          e('Find Process', 'Identify app connection process name connections',
              _switchTile('Find Process',
                  'Identify which app made each connection (shows in Connections)',
                  s.shouldFindProcess ?? false,
                  (v) => _save(s.copyWith(shouldFindProcess: v)))),
        ],
      ),
      (
        category: 'Load Balancing',
        items: [
          e('Enable Load Balancing', 'distribute direct connections multiple interfaces round-robin',
              _switchTile('Enable Load Balancing',
                  'Distribute DIRECT connections across multiple interfaces. Needs 2+ interfaces.',
                  s.loadBalanceEnabled,
                  (v) => _save(s.copyWith(loadBalanceEnabled: v)))),
          if (s.loadBalanceEnabled) ...[
            e('Strategy', 'least connections round-robin weighted failover load balance',
                _dropdownTile<String>(
                    'Strategy',
                    s.loadBalanceStrategy.isEmpty ? 'least-conn' : s.loadBalanceStrategy,
                    ['least-conn', 'round-robin', 'weighted', 'failover'],
                    (v) {
                      switch (v) {
                        case 'round-robin': return 'Round Robin — rotate evenly';
                        case 'weighted': return 'Weighted — faster gets more';
                        case 'failover': return 'Failover — primary + standby';
                        default: return 'Least Connections (recommended)';
                      }
                    },
                    (v) => _save(s.copyWith(loadBalanceStrategy: v)))),
            e('Balance Interfaces', 'select interfaces ethernet wifi adapter',
                _interfaceMultiSelectTile(
                    'Balance Interfaces',
                    'Select 2 or more interfaces',
                    s.loadBalanceInterfaces,
                    (sel) => _save(s.copyWith(loadBalanceInterfaces: sel)))),
            e('Interface Health', 'load balance status healthy',
                _loadBalanceStatusTile()),
          ],
        ],
      ),
      (
        category: 'SSL & MITM',
        items: [
          e('SSL Inspection', 'certificate corporate proxy intercept trust CA cert',
              _sslInspectionSection()),
          if (Platform.isWindows)
            e('Network Tools', 'windows network fix corporate proxy',
                _networkToolsSection()),
          e('Corporate Proxy Fix', 'MITM certificate trust install',
              _mitmSection()),
        ],
      ),
      (
        category: 'Advanced',
        items: [
          e('Check for Updates', 'update version upgrade latest',
              _checkForUpdatesTile()),
          e('Config File', 'open configuration json file path',
              _configFileTile()),
          e('Reset Network', 'clear system proxy env vars stuck internet crash',
              _resetNetworkTile()),
          e('Reset Wizard', 'dismissed wizard prompts setup restart',
              _resetWizardDismissalsTile()),
          e('PAC Rules', 'pac file proxy auto config domains',
              _pacStatusTile()),
          e('Backup Restore', 'export import configuration backup',
              _importExportTile()),
        ],
      ),
    ];

    if (isSearching) {
      // Ranked fuzzy search — score each entry and sort by relevance
      // Scoring: exact title prefix = 3, title substring = 2, full-text substring = 1, fuzzy = 0
      int score(String text, String query) {
        if (text.startsWith(query)) return 3;
        final titleEnd = text.indexOf(' ');
        final title = titleEnd > 0 ? text.substring(0, titleEnd) : text;
        if (title.contains(query)) return 2;
        if (text.contains(query)) return 1;
        // Character-order fuzzy
        int qi = 0;
        for (int i = 0; i < text.length && qi < query.length; i++) {
          if (text[i] == query[qi]) qi++;
        }
        return qi == query.length ? 0 : -1;
      }

      // Collect all matching entries with their score and category
      final scored = <({int score, String category, Widget widget})>[];
      for (final group in allGroups) {
        for (final entry in group.items) {
          final s = score(entry.text, _searchQuery);
          if (s >= 0) {
            scored.add((score: s, category: group.category, widget: entry.widget));
          }
        }
      }
      // Sort by score descending (highest relevance first)
      scored.sort((a, b) => b.score.compareTo(a.score));

      if (scored.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off, size: 32, color: Colors.grey),
              const SizedBox(height: 8),
              Text('No settings match "$_searchQuery"',
                  style: const TextStyle(color: Colors.grey)),
            ],
          ),
        );
      }

      // Group by category while preserving score order
      // Show category badge next to each item instead of section headers
      return ListView(
        padding: const EdgeInsets.all(16),
        children: scored.map((r) => Stack(
          children: [
            r.widget,
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  r.category,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          ],
        )).toList(),
      );
    }

    // Category mode — show selected category
    final group = allGroups[_selectedCategory];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TText(
            group.category,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        ...group.items.map((e) => e.widget),
      ],
    );
  }

  // ΓöÇΓöÇ DNS editing helpers ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  Future<void> _saveDnsList(String key, List<String> servers) async {
    setState(() => _isSaving = true);
    try {
      final rawRes = await widget.coreManager.dio.get(
          'http://${widget.coreManager.baseUrl}/setting');
      final raw = Map<String, dynamic>.from(rawRes.data['setting'] as Map);
      final dns = Map<String, dynamic>.from(raw['dns'] as Map? ?? {});
      final server = Map<String, dynamic>.from(dns['server'] as Map? ?? {});
      server[key] = servers;
      dns['server'] = server;
      raw['dns'] = dns;
      await widget.coreManager.dio.put(
          'http://${widget.coreManager.baseUrl}/setting', data: raw);
      // Update local state
      if (mounted) {
        setState(() {
          switch (key) {
            case 'remote': _dnsRemote = servers;
            case 'local': _dnsLocal = servers;
            case 'boost': _dnsBoost = servers;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save DNS: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _dnsListTile(String title, String subtitle, List<String> servers,
      void Function(List<String>) onSave) {
    return ListTile(
      dense: true,
      title: TText(title, style: const TextStyle(fontSize: 14)),
      subtitle: TText(
        servers.isEmpty ? subtitle : servers.join(', '),
        style: const TextStyle(fontSize: 11),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.edit, size: 18),
        onPressed: _isSaving ? null : () => _showDnsEditDialog(title, servers, onSave),
      ),
    );
  }

  Future<void> _showDnsEditDialog(String title, List<String> current,
      void Function(List<String>) onSave) async {
    // Preset options per category (matching web UI)
    List<String> presets;
    if (title.contains('Remote')) {
      presets = [
        'tcp://8.8.8.8:53',
        'tcp://1.1.1.1:53',
        'https://dns.google/dns-query',
        'https://cloudflare-dns.com/dns-query',
      ];
    } else if (title.contains('Boost')) {
      presets = [
        'tcp://114.114.114.114:53',
        'tcp://119.29.29.29:53',
        'dhcp://auto',
        'system://auto',
      ];
    } else {
      // Local
      presets = [
        'tcp://114.114.114.114:53',
        'tcp://119.29.29.29:53',
        'https://doh.pub/dns-query',
        'dhcp://auto',
        'system://auto',
      ];
    }

    // Merge presets + any custom entries already selected
    final allOptions = <String>{...presets, ...current}.toList();
    final selected = Set<String>.from(current);

    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => _DnsPickerDialog(
        title: title,
        allOptions: allOptions,
        initialSelected: selected,
      ),
    );
    if (result != null) {
      onSave(result);
    }
  }

  // ΓöÇΓöÇ Language / Theme helpers ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  String _currentLanguage() {
    final appState = Provider.of<AppStateModel>(context, listen: false);
    final code = appState.locale.languageCode;
    if (code == 'zh') return 'zh-CN';
    const known = ['fil', 'es', 'fr', 'pt', 'ar', 'de', 'ja', 'ko', 'en'];
    if (known.contains(code)) return code;
    return 'system';
  }

  String _languageLabel(String v) {
    switch (v) {
      case 'en':    return 'English';
      case 'zh-CN': return '简体中文';
      case 'fil':   return 'Filipino';
      case 'es':    return 'Español';
      case 'fr':    return 'Français';
      case 'pt':    return 'Português';
      case 'ar':    return 'العربية';
      case 'de':    return 'Deutsch';
      case 'ja':    return '日本語';
      case 'ko':    return '한국어';
      default:      return 'System';
    }
  }

  Future<void> _saveLanguage(String v) async {
    final appState = Provider.of<AppStateModel>(context, listen: false);
    setState(() => _isSaving = true);
    try {
      final current = await widget.coreManager.dio.get(
          'http://${widget.coreManager.baseUrl}/setting');
      final raw = Map<String, dynamic>.from(current.data['setting'] as Map);
      raw['language'] = v;
      await widget.coreManager.dio.put(
          'http://${widget.coreManager.baseUrl}/setting', data: raw);
      // Only update UI after successful save
      appState.updateLocale(convertLocale(v));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save language: $e')),
        );
        // Revert — nothing to revert since UI not changed yet
        setState(() {}); // re-render to show previous value in dropdown
        debugPrint('Failed to save language: $e');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _currentTheme() {
    final appState = Provider.of<AppStateModel>(context, listen: false);
    switch (appState.theme) {
      case ThemeMode.dark: return 'dark';
      case ThemeMode.light: return 'light';
      default: return 'system';
    }
  }

  String _themeLabel(String v) {
    switch (v) {
      case 'dark': return 'Dark';
      case 'light': return 'Light';
      default: return 'System';
    }
  }

  Future<void> _saveTheme(String v) async {
    final appState = Provider.of<AppStateModel>(context, listen: false);
    setState(() => _isSaving = true);
    try {
      final current = await widget.coreManager.dio.get(
          'http://${widget.coreManager.baseUrl}/setting');
      final raw = Map<String, dynamic>.from(current.data['setting'] as Map);
      raw['theme'] = v;
      await widget.coreManager.dio.put(
          'http://${widget.coreManager.baseUrl}/setting', data: raw);
      // Only update UI after successful save
      appState.updateTheme(convertTheme(v));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save theme: $e')),
        );
        setState(() {}); // re-render to show previous value
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ΓöÇΓöÇ Config File tile ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  // ΓöÇΓöÇ Config Import / Export ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  Widget _importExportTile() {
    return ListTile(
      dense: true,
      title: TText('Backup & Restore', style: TextStyle(fontSize: 14)),
      subtitle: TText('Export or import your full configuration', style: TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: _isSaving ? null : _exportConfig,
            child: TText('Export', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: _isSaving ? null : _importConfig,
            child: TText('Import', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _exportConfig() async {
    try {
      final homeDir = await getHomeDir();
      final source = File('$homeDir/config.json');
      if (!source.existsSync()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('config.json not found')));
        return;
      }

      // Try native save dialog via osascript
      String savePath = '';
      try {
        final result = await Process.run('/usr/bin/osascript', [
          '-e',
          'tell application "Finder" to activate\ntell application "Finder" to set p to POSIX path of (choose file name with prompt "Save config backup as:" default name "lux-config-backup.json")\nreturn p',
        ]).timeout(const Duration(seconds: 30));
        savePath = result.stdout.toString().trim();
      } catch (_) {}

      // Fallback: save to Desktop
      if (savePath.isEmpty) {
        final desktop = '${Platform.environment['HOME']}/Desktop/lux-config-backup.json';
        savePath = desktop;
      }

      await source.copy(savePath);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Config exported to $savePath')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _importConfig() async {
    try {
      // Try native open dialog via osascript
      String filePath = '';
      try {
        final result = await Process.run('/usr/bin/osascript', [
          '-e',
          'tell application "Finder" to activate\ntell application "Finder" to set p to POSIX path of (choose file with prompt "Select a Lux config backup:" of type {"public.json", "json"})\nreturn p',
        ]).timeout(const Duration(seconds: 30));
        filePath = result.stdout.toString().trim();
      } catch (_) {}

      // Fallback: ask user to type path
      if (filePath.isEmpty) {
        if (!mounted) return;
        final controller = TextEditingController();
        final typed = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: TText('Import Config'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Path to config.json',
                hintText: '/Users/.../lux-config-backup.json',
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: TText('Cancel')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: TText('Open')),
            ],
          ),
        );
        if (typed == null || typed.isEmpty) return;
        filePath = typed;
      }

      final source = File(filePath);
      if (!source.existsSync()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File not found: $filePath')));
        return;
      }
      final content = await source.readAsString();
      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(content) as Map<String, dynamic>;
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('Invalid JSON'), backgroundColor: Colors.red));
        return;
      }
      if (!parsed.containsKey('setting') && !parsed.containsKey('proxy')) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('Not a valid Lux config'), backgroundColor: Colors.red));
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: TText('Import Config'),
          content: TText('Replaces current config. Restart to apply. Continue?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: TText('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: TText('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final homeDir = await getHomeDir();
      final dest = File('$homeDir/config.json');
      await dest.copy('$homeDir/config.json.bak');
      await source.copy(dest.path);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: TText('Imported. Restart Lux to apply.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e'), backgroundColor: Colors.red));
    }
  }

  Widget _pacStatusTile() {
    return FutureBuilder<Map<String, dynamic>>(
      future: widget.coreManager.getPacStatus(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final data = snap.data!;
        final active = data['active'] as bool? ?? false;
        final count = data['count'] as int? ?? 0;
        final url = data['url'] as String? ?? '';
        final domains = List<String>.from(data['domains'] as List? ?? []);
        final cidrs = List<String>.from(data['cidrs'] as List? ?? []);

        return ListTile(
          dense: true,
          title: Row(children: [
            TText('PAC Rules', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            if (active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('$count active',
                    style: const TextStyle(fontSize: 10, color: Colors.green)),
              ),
          ]),
          subtitle: active
              ? Text(
                  'From: $url\n'
                  'DIRECT domains: ${domains.take(3).join(", ")}${domains.length > 3 ? "..." : ""}\n'
                  'DIRECT CIDRs: ${cidrs.take(2).join(", ")}${cidrs.length > 2 ? "..." : ""}',
                  style: const TextStyle(fontSize: 11),
                )
              : TText('No PAC file detected on this network',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
          trailing: active
              ? IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  tooltip: 'Refresh',
                  onPressed: () => setState(() {}),
                )
              : null,
        );
      },
    );
  }

  Widget _checkForUpdatesTile() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: const Icon(Icons.system_update_alt, size: 20),
      title: TText('Check for Updates', style: TextStyle(fontSize: 14)),
      subtitle: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (ctx, snap) => Text(
          'Current: ${snap.data?.version ?? '…'}',
          style: const TextStyle(fontSize: 12),
        ),
      ),
      trailing: _checking
          ? const SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right, size: 20),
      onTap: _checking ? null : _doCheckForUpdates,
    );
  }

  bool _checking = false;

  Future<void> _doCheckForUpdates() async {
    setState(() => _checking = true);
    try {
      final info = await checkForUpdate();
      if (!mounted) return;
      if (info == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('Could not reach update server')));
        return;
      }
      if (!info.hasUpdate) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lux ${info.currentVersion} is up to date ✓')));
        return;
      }
      await showUpdateDialog(context, info);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Widget _resetNetworkTile() {
    return ListTile(
      dense: true,
      title: TText('Reset Network', style: TextStyle(fontSize: 14)),
      subtitle: const Text(
          'Clear system proxy + env vars if internet is stuck after crash',
          style: TextStyle(fontSize: 12)),
      trailing: TextButton(
        style: TextButton.styleFrom(foregroundColor: Colors.orange),
        onPressed: _isSaving
            ? null
            : () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: TText('Reset Network Settings?'),
                    content: const Text(
                        'This clears the system proxy, HTTP_PROXY env vars, and git proxy. '
                        'Use this if internet is broken after Lux crashed.\n\n'
                        'You will need to reconnect Lux afterwards.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: TText('Cancel')),
                      FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.orange),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: TText('Reset')),
                    ],
                  ),
                );
                if (confirmed != true || !mounted) return;
                await NetworkReset.reset();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: TText('Network settings reset. Reconnect Lux to use proxy.')),
                  );
                }
              },
        child: TText('Reset', style: TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _resetWizardDismissalsTile() {
    return ListTile(
      dense: true,
      title: TText('Reset Setup Wizard', style: TextStyle(fontSize: 14)),
      subtitle: const Text(
          'Re-enable all "Don\'t ask again" wizard steps for re-configuration',
          style: TextStyle(fontSize: 12)),
      trailing: TextButton(
        onPressed: _isSaving
            ? null
            : () async {
                await clearDismissedWizardSteps();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: TText('Wizard steps reset — they will show again on next network connection.'),
                    ),
                  );
                }
              },
        child: TText('Reset', style: TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _configFileTile() {
    return ListTile(
      dense: true,
      title: TText('Config File', style: TextStyle(fontSize: 14)),
      subtitle: TText('Open or reset your configuration', style: TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () async {
              final homeDir = await getHomeDir();
              launchUrl(Uri.file(homeDir));
            },
            child: TText('Open Dir', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: _isSaving ? null : () => _confirmResetConfig(),
            child: TText('Reset', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmResetConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: TText('Reset Configuration'),
        content: const Text(
          'This will reset all settings to defaults. The app will restart. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: TText('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: TText('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.coreManager.dio.post(
          'http://${widget.coreManager.baseUrl}/setting/reset');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: TText('Config reset. Restart the app.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reset failed: $e')),
        );
      }
    }
  }

  // ΓöÇΓöÇ SSL Inspection ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  Future<void> _checkSslBump() async {
    setState(() {
      _sslChecking = true;
      _installResult = null;
    });
    try {
      // Get the currently selected proxy to route the probe through it.
      // This is what actually sees the SSL bump — probing direct misses it.
      String? proxyAddr;
      try {
        final proxyList = await widget.coreManager.getProxyList();
        final selectedId = proxyList.id;
        if (selectedId.isNotEmpty && selectedId != 'DIRECT') {
          final detail = await widget.coreManager.getProxyDetail(selectedId);
          if (detail != null &&
              detail.server != null &&
              detail.port != null &&
              (detail.type == 'http' || detail.type == 'https')) {
            proxyAddr = '${detail.server}:${detail.port}';
            // Include credentials if present
            final user = detail.raw['username'] as String? ?? '';
            final pass = detail.password ?? '';
            if (user.isNotEmpty) {
              final eu = Uri.encodeComponent(user);
              final ep = Uri.encodeComponent(pass);
              proxyAddr = '$eu:$ep@${detail.server}:${detail.port}';
            }
          }
        }
      } catch (_) {}

      final status = await widget.coreManager.getSslBumpStatus(
        proxyAddr: proxyAddr,
        fresh: true,
      );
      if (mounted) setState(() => _sslStatus = status);
    } catch (e) {
      if (mounted) {
        setState(() => _sslStatus = SslBumpStatus(
              detected: false,
              hasCert: false,
              error: e.toString(),
            ));
      }
    } finally {
      if (mounted) setState(() => _sslChecking = false);
    }
  }

  Future<void> _installCert() async {
    final status = _sslStatus;
    if (status == null || !status.hasCert) return;

    // Show cert details + explicit confirmation before doing anything
    final confirmed = await _showCertConfirmDialog(status.certInfo);
    if (!confirmed || !mounted) return;

    setState(() {
      _sslInstalling = true;
      _installResult = null;
    });
    try {
      final pemBytes = await widget.coreManager.getSslBumpCert();
      if (pemBytes == null || pemBytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: TText('No certificate available to install')),
          );
        }
        return;
      }
      final result = await CertInstaller.install(pemBytes);
      if (mounted) setState(() => _installResult = result);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.success
                ? 'Certificate installed successfully'
                : 'Installation partially failed — see details below'),
            backgroundColor:
                result.success ? Colors.green.shade700 : Colors.orange.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Install error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sslInstalling = false);
    }
  }

  /// Shows a dialog with the intercepting cert's details and asks the user
  /// to explicitly confirm before trusting it system-wide.
  Future<bool> _showCertConfirmDialog(CertInfo? info) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 22),
                SizedBox(width: 8),
                Flexible(child: TText('Trust this certificate?', style: TextStyle(fontSize: 16))),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Your proxy is intercepting HTTPS traffic. Installing this CA '
                    'will make your system trust all certificates it signs — only '
                    'do this if you trust the organization that controls this proxy.',
                    style: TextStyle(fontSize: 13),
                  ),
                  if (info != null) ...[
                    const SizedBox(height: 16),
                    _certDetailTable(info),
                  ] else ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Certificate details unavailable.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade800.withValues(alpha: 0.15),
                      border: Border.all(color: Colors.orange.shade600),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 14, color: Colors.orange),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'This grants the proxy the ability to decrypt and read '
                            'all your HTTPS traffic. Only proceed if this is your '
                            'corporate or personal proxy.',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: TText('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: TText('I trust this — install'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget _certDetailTable(CertInfo info) {
    final rows = [
      if (info.subject.isNotEmpty) ('Subject', info.subject),
      if (info.organizationName.isNotEmpty) ('Organization', info.organizationName),
      if (info.issuer.isNotEmpty && info.issuer != info.subject) ('Issuer', info.issuer),
      ('Valid from', info.notBefore),
      ('Valid until', info.notAfter),
      if (info.sha256Fingerprint.isNotEmpty) ('SHA-256', info.sha256Fingerprint),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: rows.map((r) {
          final isLast = r == rows.last;
          return Container(
            decoration: BoxDecoration(
              border: isLast
                  ? null
                  : Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 88,
                  child: Text(r.$1,
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w500)),
                ),
                Expanded(
                  child: Text(r.$2,
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace'),
                      softWrap: true),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Compact inline cert preview shown in the settings page (not the dialog).
  Widget _certPreviewCard(CertInfo? info) {
    if (info == null) return const SizedBox.shrink();
    final display = info.organizationName.isNotEmpty ? info.organizationName : info.subject;
    final fp = info.sha256Fingerprint.length > 29
        ? '${info.sha256Fingerprint.substring(0, 29)}…'
        : info.sha256Fingerprint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.amber.shade600),
        borderRadius: BorderRadius.circular(6),
        color: Colors.amber.shade800.withValues(alpha: 0.15),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TText('Intercepting CA',
              style: TextStyle(fontSize: 10, color: Colors.amber.shade400, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          if (display.isNotEmpty)
            Text(display, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          if (fp.isNotEmpty)
            Text('SHA-256: $fp',
                style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.grey.shade700)),
          Text('Valid: ${info.notBefore} / ${info.notAfter}',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _sslInspectionSection() {
    final status = _sslStatus;

    // Status indicator chip
    Widget statusChip;
    if (_sslChecking) {
      statusChip = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 6),
          TText('Checking…', style: TextStyle(fontSize: 12)),
        ],
      );
    } else if (status == null) {
      statusChip = TText('Not checked yet', style: TextStyle(fontSize: 12, color: Colors.grey));
    } else if (status.error != null && status.error!.isNotEmpty) {
      statusChip = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 14, color: Colors.orange.shade700),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Probe failed: ${status.error}',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (status.detected) {
      statusChip = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: Colors.amber.shade700),
          const SizedBox(width: 4),
          TText('SSL inspection detected',
              style: TextStyle(fontSize: 12, color: Colors.amber.shade700, fontWeight: FontWeight.w600)),
        ],
      );
    } else {
      statusChip = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
          SizedBox(width: 4),
          TText('No interception detected', style: TextStyle(fontSize: 12, color: Colors.green)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TText('Detect SSL Bumping', style: TextStyle(fontSize: 14)),
                    const SizedBox(height: 2),
                    const Text(
                      'Check if your proxy intercepts HTTPS traffic and install its CA certificate so curl, git, npm, and Python trust it.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                icon: const Icon(Icons.search, size: 16),
                label: TText('Check', style: TextStyle(fontSize: 12)),
                onPressed: _sslChecking ? null : _checkSslBump,
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        if (status != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: statusChip,
          ),
          if (status.detected && status.hasCert) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _certPreviewCard(status.certInfo),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
                icon: _sslInstalling
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.verified_user, size: 16),
                label: Text(
                  _sslInstalling ? 'Installing…' : 'Install Certificate…',
                  style: const TextStyle(fontSize: 13),
                ),
                onPressed: _sslInstalling ? null : _installCert,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                Platform.isWindows
                    ? 'Installs into Windows Trusted Root (all users), Git for Windows, Node.js, and Python certifi.'
                    : 'Installs into macOS System Keychain (all users), curl/OpenSSL, and Node.js. Homebrew openssl, Firefox, and Python certifi installed if present.',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
          if (!status.detected && status.hasCert)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'A certificate was previously captured. You can still install it.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
          // Show previous install results
          if (_installResult != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _installResultWidget(_installResult!),
            ),
          ],
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _installResultWidget(InstallResult result) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: result.success ? Colors.green.shade300 : Colors.orange.shade300,
        ),
        borderRadius: BorderRadius.circular(8),
        color: result.success
            ? Colors.green.shade50.withValues(alpha: 0.3)
            : Colors.orange.shade50.withValues(alpha: 0.3),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.success ? Icons.check_circle : Icons.warning_amber_rounded,
                size: 16,
                color: result.success ? Colors.green.shade700 : Colors.orange.shade700,
              ),
              const SizedBox(width: 6),
              Text(
                result.success ? 'Installation complete' : 'Partial install',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: result.success ? Colors.green.shade700 : Colors.orange.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...result.steps.map((step) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      step.success ? Icons.check : Icons.close,
                      size: 13,
                      color: step.success ? Colors.green : Colors.red.shade400,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${step.name}: ${step.note}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  // ── Network Tools (Windows) ────────────────────────────────────────────────

  Widget _networkToolsSection() {
    final tools = [
      _NetworkTool(
        icon: Icons.refresh,
        label: 'Renew IP',
        description: 'Release and renew DHCP lease — fixes "no internet" after waking from sleep',
        color: Colors.blue,
        onRun: () => _runNetworkTool('Renew IP', () async {
          await Process.run('ipconfig', ['/release'], runInShell: true);
          await Process.run('ipconfig', ['/renew'], runInShell: true);
          return 'IP address renewed';
        }),
      ),
      _NetworkTool(
        icon: Icons.dns_outlined,
        label: 'Flush DNS',
        description: 'Clear DNS cache — fixes sites that stopped resolving',
        color: Colors.teal,
        onRun: () => _runNetworkTool('Flush DNS', () async {
          final r = await Process.run('ipconfig', ['/flushdns'], runInShell: true);
          return r.exitCode == 0 ? 'DNS cache flushed' : 'Failed: ${r.stderr}';
        }),
      ),
      _NetworkTool(
        icon: Icons.cleaning_services_outlined,
        label: 'Clear ARP Cache',
        description: 'Fix LAN connection issues with other devices',
        color: Colors.orange,
        onRun: () => _runNetworkTool('Clear ARP Cache', () async {
          final r = await Process.run('arp', ['-d', '*'], runInShell: true);
          return r.exitCode == 0 ? 'ARP cache cleared' : 'Cleared (some entries may persist)';
        }),
      ),
      _NetworkTool(
        icon: Icons.settings_backup_restore,
        label: 'Reset Proxy Settings',
        description: 'Restore system proxy if lux crashed and left proxy misconfigured',
        color: Colors.purple,
        onRun: () => _runNetworkTool('Reset Proxy', () async {
          await NetworkReset.reset();
          return 'Proxy settings restored';
        }),
      ),
      _NetworkTool(
        icon: Icons.warning_amber_outlined,
        label: 'Reset Winsock',
        description: 'Fix corrupted network stack — requires restart',
        color: Colors.red,
        requiresRestart: true,
        onRun: () => _runNetworkTool('Reset Winsock', () async {
          final r = await Process.run('netsh', ['winsock', 'reset'], runInShell: true);
          return r.exitCode == 0 ? 'Winsock reset — please restart your PC' : 'Failed: ${r.stderr}';
        }),
      ),
      _NetworkTool(
        icon: Icons.dangerous_outlined,
        label: 'Reset TCP/IP Stack',
        description: 'Nuclear fix for persistent network issues — requires restart',
        color: Colors.red.shade800,
        requiresRestart: true,
        onRun: () => _runNetworkTool('Reset TCP/IP', () async {
          final r = await Process.run('netsh', ['int', 'ip', 'reset'], runInShell: true);
          return r.exitCode == 0 ? 'TCP/IP reset — please restart your PC' : 'Failed: ${r.stderr}';
        }),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Status message
        if (_networkToolStatus != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(child: Text(_networkToolStatus!,
                    style: const TextStyle(fontSize: 12))),
                GestureDetector(
                  onTap: () => setState(() => _networkToolStatus = null),
                  child: const Icon(Icons.close, size: 14, color: Colors.grey),
                ),
              ]),
            ),
          ),
        // Tool buttons grid
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tools.map((tool) => _networkToolButton(tool)).toList(),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _networkToolButton(_NetworkTool tool) {
    return Tooltip(
      message: tool.description,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: tool.color,
          side: BorderSide(color: tool.color.withValues(alpha: 0.4)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 12),
        ),
        icon: Icon(tool.icon, size: 14),
        label: Text(tool.label),
        onPressed: tool.onRun,
      ),
    );
  }

  Future<void> _runNetworkTool(String name, Future<String> Function() action) async {
    try {
      final result = await action();
      if (mounted) setState(() => _networkToolStatus = '$name: $result');
    } catch (e) {
      if (mounted) setState(() => _networkToolStatus = '$name failed: $e');
    }
  }

  // ── Corporate Proxy Fix (MITM) ────────────────────────────────────────────

  Widget _mitmSection() {
    return FutureBuilder<Map<String, dynamic>>(
      future: widget.coreManager.getMitmSettings(),
      builder: (ctx, snap) {
        final data = snap.data ?? {};
        final enabled = data['enabled'] as bool? ?? false;
        final fingerprint = data['caFingerprint'] as String?;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Description
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Fixes apps that fail with certificate revocation errors '
                '(CRYPT_E_NO_REVOCATION_CHECK) when behind a corporate SSL-inspecting proxy. '
                'Lux acts as a local TLS proxy for selected domains, adding proper CRL/OCSP endpoints to generated certs.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
            // Enable toggle
            ListTile(
              dense: true,
              title: TText('Enable Corporate Proxy Fix', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                enabled ? 'Active — intercepting configured domains' : 'Disabled',
                style: TextStyle(fontSize: 12,
                    color: enabled ? Colors.green : Colors.grey),
              ),
              trailing: Switch(
                value: enabled,
                onChanged: _isSaving ? null : (v) async {
                  setState(() => _isSaving = true);
                  try {
                    await widget.coreManager.setMitmEnabled(v);
                    setState(() {}); // trigger FutureBuilder rebuild
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed: $e')));
                  } finally {
                    if (mounted) setState(() => _isSaving = false);
                  }
                },
              ),
            ),
            // CA cert info + install button
            if (fingerprint != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      TText('Local CA Certificate',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      Text(fingerprint.substring(0, 29) + '…',
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace',
                              color: Colors.grey)),
                    ]),
                  ),
                  TextButton.icon(
                    icon: _mitmCaInstalling
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.install_desktop, size: 15),
                    label: Text(_mitmCaInstalling ? 'Installing…' : 'Install CA',
                        style: const TextStyle(fontSize: 12)),
                    onPressed: _mitmCaInstalling ? null : () => _installMitmCA(),
                  ),
                ]),
              ),
            ],
            // Inspection list
            if (enabled) _mitmInspectionListTile(),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Future<void> _installMitmCA() async {
    setState(() => _mitmCaInstalling = true);
    // Show "Installing…" snackbar immediately
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        SizedBox(width: 12),
        TText('Installing CA certificate…'),
      ]),
      duration: Duration(seconds: 30),
    ));
    try {
      final pemBytes = await widget.coreManager.getMitmCAPem();
      if (pemBytes == null || pemBytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: TText('CA not available — enable Corporate Proxy Fix first')));
        }
        return;
      }
      // Install directly via X509Store — no C:\Windows\Temp needed, no admin required
      final result = await _installCertViaX509Store(pemBytes);
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result ? 'CA certificate installed successfully' : 'Installation failed'),
          backgroundColor: result ? Colors.green : Colors.red,
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _mitmCaInstalling = false);
    }
  }

  /// Installs a PEM cert directly into CurrentUser\Root via PowerShell X509Store.
  /// No C:\Windows\Temp write needed — no admin required.
  Future<bool> _installCertViaX509Store(List<int> pemBytes) async {
    if (!Platform.isWindows) {
      // macOS: use CertInstaller
      final result = await CertInstaller.install(pemBytes);
      return result.success;
    }
    final pem = String.fromCharCodes(pemBytes);
    final b64 = pem
        .replaceAll('-----BEGIN CERTIFICATE-----', '')
        .replaceAll('-----END CERTIFICATE-----', '')
        .replaceAll('\n', '').replaceAll('\r', '').trim();
    final result = await Process.run('powershell.exe', [
      '-noprofile', '-NonInteractive', '-command',
      r'''
$b64 = "''' + b64 + r'''"
$bytes = [System.Convert]::FromBase64String($b64)
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,[byte[]]$bytes)
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root","CurrentUser"
$store.Open("ReadWrite")
$store.Add($cert)
$store.Close()
Write-Output "ok"
''',
    ]);
    return result.stdout.toString().trim() == 'ok';
  }

  Widget _mitmInspectionListTile() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: widget.coreManager.getMitmInspectionEntries(),
      builder: (ctx, snap) {
        final entries = snap.data ?? [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                TText('Inspection Domains',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 15),
                  label: TText('Add', style: TextStyle(fontSize: 12)),
                  onPressed: () => _addMitmPattern(),
                ),
              ]),
            ),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TText('No domains configured. Add domains like *.blackmagicdesign.com',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              )
            else
              ...entries.map((e) {
                final pattern = e['pattern'] as String? ?? '';
                final active = e['enabled'] as bool? ?? true;
                return ListTile(
                  dense: true,
                  title: Text(pattern,
                      style: TextStyle(fontSize: 13,
                          color: active ? null : Colors.grey,
                          decoration: active ? null : TextDecoration.lineThrough)),
                  leading: Icon(Icons.security,
                      size: 16, color: active ? Colors.orange : Colors.grey),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: Icon(active ? Icons.toggle_on : Icons.toggle_off,
                          size: 20, color: active ? Colors.green : Colors.grey),
                      onPressed: () async {
                        await widget.coreManager.toggleMitmPattern(pattern);
                        setState(() {});
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                      onPressed: () async {
                        await widget.coreManager.removeMitmPattern(pattern);
                        setState(() {});
                      },
                    ),
                  ]),
                );
              }),
          ],
        );
      },
    );
  }

  Future<void> _addMitmPattern() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: TText('Add Inspection Domain', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Domain pattern',
            hintText: '*.blackmagicdesign.com',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 13),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null),
              child: TText('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: TText('Add')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      try {
        await widget.coreManager.addMitmPattern(result);
        setState(() {});
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to add: $e')));
      }
    }
  }

  Widget _resetDismissedProxiesTile() {
    return ListTile(
      dense: true,
      title: TText('Proxy Detection', style: TextStyle(fontSize: 14)),
      subtitle: TText('Re-show startup proxy detection dialogs',
          style: TextStyle(fontSize: 12)),
      trailing: TextButton(
        onPressed: () async {
          await clearDismissedProxies();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: TText('Proxy detection dialogs will show again on next launch'),
                duration: Duration(seconds: 3),
              ),
            );
          }
        },
        child: TText('Reset', style: TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _clearSavedProxyTile() {
    return ListTile(
      dense: true,
      title: TText('Saved Proxy Address', style: TextStyle(fontSize: 14)),
      subtitle: const Text(
          'Clear the proxy address saved from before Lux was installed. '
          'Use this if the wrong proxy is being pre-filled at startup.',
          style: TextStyle(fontSize: 12)),
      trailing: TextButton(
        onPressed: () async {
          try {
            await Process.run('reg', [
              'delete', r'HKCU\Software\LuxProxy',
              '/v', 'OriginalProxyServer', '/f'
            ]);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: TText('Saved proxy address cleared'),
                  duration: Duration(seconds: 2)));
          } catch (e) {
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed: $e')));
          }
        },
        child: TText('Clear', style: TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TText(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _switchTile(
      String title, String subtitle, bool value, void Function(bool) onChanged) {
    return SwitchListTile(
      title: TText(title, style: const TextStyle(fontSize: 14)),
      subtitle: TText(subtitle, style: const TextStyle(fontSize: 12)),
      value: value,
      dense: true,
      onChanged: _isSaving ? null : onChanged,
    );
  }

  Widget _dropdownTile<T>(String title, T value, List<T> options,
      String Function(T) label, void Function(T) onChanged) {
    return ListTile(
      dense: true,
      title: TText(title, style: const TextStyle(fontSize: 14)),
      trailing: DropdownButton<T>(
        value: value,
        items: options
            .map((o) => DropdownMenuItem(value: o, child: TText(label(o), style: const TextStyle(fontSize: 13))))
            .toList(),
        onChanged: _isSaving ? null : (v) { if (v != null) onChanged(v); },
        underline: const SizedBox(),
      ),
    );
  }

  Widget _numberTile(String title, int value, void Function(int) onChanged) {
    return ListTile(
      dense: true,
      title: TText(title, style: const TextStyle(fontSize: 14)),
      trailing: SizedBox(
        width: 80,
        child: TextFormField(
          initialValue: value.toString(),
          keyboardType: TextInputType.number,
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            border: OutlineInputBorder(),
          ),
          onFieldSubmitted: (v) {
            final n = int.tryParse(v);
            if (n != null) onChanged(n);
          },
        ),
      ),
    );
  }

  Widget _interfaceMultiSelectTile(String title, String subtitle,
      List<String> selected, void Function(List<String>) onChanged) {
    return ListTile(
      dense: true,
      title: TText(title, style: const TextStyle(fontSize: 14)),
      subtitle: TText(
        selected.isEmpty ? 'None selected' : selected.join(', '),
        style: const TextStyle(fontSize: 12),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: _isSaving
          ? null
          : () async {
              final result = await showDialog<List<String>>(
                context: context,
                builder: (ctx) => _InterfacePickerDialog(
                  allInterfaces: _interfaces,
                  initialSelected: selected,
                ),
              );
              if (result != null) onChanged(result);
            },
    );
  }

  Widget _loadBalanceStatusTile() {
    return FutureBuilder<Map<String, dynamic>>(
      future: widget.coreManager.getLoadBalanceStatus(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final data = snap.data!;
        final healthy = List<String>.from(data['healthy'] as List? ?? []);
        final all = List<String>.from(data['interfaces'] as List? ?? []);
        final next = data['next'] as String? ?? '';
        final strategy = data['strategy'] as String? ?? '';
        final latencies = (data['latencies'] as Map?)?.map(
            (k, v) => MapEntry(k as String, (v as num).toInt())) ?? <String, int>{};
        if (all.isEmpty) return const SizedBox.shrink();

        String displayName(String iface) {
          if (iface.contains('(')) {
            return iface.substring(0, iface.lastIndexOf('(')).trim();
          }
          return iface;
        }

        String strategyLabel(String s) {
          switch (s) {
            case 'round-robin': return 'Round Robin';
            case 'failover':    return 'Failover';
            case 'weighted':    return 'Weighted';
            default:            return 'Least Connections';
          }
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                TText('Interface Health',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                const Spacer(),
                if (strategy.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(strategyLabel(strategy),
                        style: const TextStyle(fontSize: 10, color: Colors.blue)),
                  ),
                if (next.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('next: ${displayName(next)}',
                        style: const TextStyle(fontSize: 10, color: Colors.green)),
                  ),
                ],
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => setState(() {}),
                  child: const Icon(Icons.refresh, size: 14, color: Colors.grey),
                ),
              ]),
              const SizedBox(height: 6),
              ...all.map((iface) {
                final isHealthy = healthy.contains(iface);
                final isNext = iface == next;
                return Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(children: [
                    Icon(Icons.circle,
                        size: 7,
                        color: isHealthy ? Colors.green : Colors.red),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        displayName(iface),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: isNext ? FontWeight.w600 : FontWeight.normal,
                            color: isHealthy ? null : Colors.red),
                      ),
                    ),
                    // Show latency if available (weighted strategy or background measurement)
                    Builder(builder: (_) {
                      final rawName = iface.contains('(')
                          ? iface.split('(').last.replaceAll(')', '').trim()
                          : iface;
                      final ms = latencies[rawName];
                      if (ms == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text('${ms}ms',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                      );
                    }),
                    if (isNext)
                      TText('← next',
                          style: TextStyle(fontSize: 10, color: Colors.green)),
                    if (!isHealthy)
                      TText('unreachable',
                          style: TextStyle(fontSize: 10, color: Colors.red)),
                  ]),
                );
              }),
              if (healthy.length >= 2) ...[
                const SizedBox(height: 6),
                const Text(
                  '✓ Active — balancing across interfaces',
                  style: TextStyle(fontSize: 11, color: Colors.green),
                ),
              ] else if (healthy.length == 1) ...[
                const SizedBox(height: 6),
                Text(
                  '⚠ Only 1 interface healthy — using ${displayName(healthy.first)} only',
                  style: const TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ] else ...[
                const SizedBox(height: 6),
                const Text(
                  '✗ No healthy interfaces — falling back to default',
                  style: TextStyle(fontSize: 11, color: Colors.red),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _textFieldTile(String title, String value, String hint,
      void Function(String) onChanged) {
    return ListTile(
      dense: true,
      title: TText(title, style: const TextStyle(fontSize: 14)),
      subtitle: TextFormField(
        initialValue: value,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          border: const OutlineInputBorder(),
        ),
        onFieldSubmitted: onChanged,
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
    default:
      return 'Mixed';
  }
}

// ΓöÇΓöÇ DNS Picker Dialog ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

class _DnsOption {
  final String value;
  final String label;
  final String description;

  const _DnsOption(this.value, this.label, this.description);
}

const _allDnsOptions = <_DnsOption>[
  _DnsOption('tcp://8.8.8.8:53', 'Google DNS', 'TCP ┬╖ 8.8.8.8:53 ┬╖ Fast, global'),
  _DnsOption('tcp://1.1.1.1:53', 'Cloudflare DNS', 'TCP ┬╖ 1.1.1.1:53 ┬╖ Privacy-focused'),
  _DnsOption('tcp://114.114.114.114:53', '114 DNS', 'TCP ┬╖ 114.114.114.114:53 ┬╖ China mainland'),
  _DnsOption('tcp://119.29.29.29:53', 'DNSPod', 'TCP ┬╖ 119.29.29.29:53 ┬╖ Tencent China'),
  _DnsOption('tcp://223.5.5.5:53', 'AliDNS', 'TCP ┬╖ 223.5.5.5:53 ┬╖ Alibaba China'),
  _DnsOption('https://dns.google/dns-query', 'Google DoH', 'HTTPS ┬╖ Encrypted DNS-over-HTTPS'),
  _DnsOption('https://cloudflare-dns.com/dns-query', 'Cloudflare DoH', 'HTTPS ┬╖ Encrypted DNS-over-HTTPS'),
  _DnsOption('https://doh.pub/dns-query', 'DNSPod DoH', 'HTTPS ┬╖ Tencent encrypted DNS (China)'),
  _DnsOption('dhcp://auto', 'DHCP Auto', 'Uses DNS from your router/DHCP server'),
  _DnsOption('system://auto', 'System Auto', 'Uses your OS-configured DNS servers'),
  _DnsOption('udp://8.8.8.8:53', 'Google UDP', 'UDP ┬╖ 8.8.8.8:53 ┬╖ Traditional DNS'),
  _DnsOption('udp://1.1.1.1:53', 'Cloudflare UDP', 'UDP ┬╖ 1.1.1.1:53 ┬╖ Traditional DNS'),
];

class _DnsPickerDialog extends StatefulWidget {
  final String title;
  final List<String> allOptions;
  final Set<String> initialSelected;

  const _DnsPickerDialog({
    required this.title,
    required this.allOptions,
    required this.initialSelected,
  });

  @override
  State<_DnsPickerDialog> createState() => _DnsPickerDialogState();
}

class _DnsPickerDialogState extends State<_DnsPickerDialog> {
  late Set<String> _selected;
  late List<String> _options;
  final _searchController = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelected);
    _options = List<String>.from(widget.allOptions);
    _searchController.addListener(() {
      setState(() => _filter = _searchController.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  _DnsOption _optionFor(String value) {
    return _allDnsOptions.firstWhere(
      (o) => o.value == value,
      orElse: () => _DnsOption(value, value, 'Custom server'),
    );
  }

  bool _matchesFilter(_DnsOption opt) {
    if (_filter.isEmpty) return true;
    return opt.value.toLowerCase().contains(_filter) ||
        opt.label.toLowerCase().contains(_filter) ||
        opt.description.toLowerCase().contains(_filter);
  }

  void _addCustom() {
    final value = _searchController.text.trim();
    if (value.isEmpty) return;
    final validPrefixes = ['tcp://', 'https://', 'udp://', 'dhcp://', 'system://'];
    if (!validPrefixes.any((p) => value.startsWith(p))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Must start with: ${validPrefixes.join(", ")}')),
      );
      return;
    }
    setState(() {
      if (!_options.contains(value)) _options.add(value);
      _selected.add(value);
    });
    _searchController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _options.map(_optionFor).where(_matchesFilter).toList();
    // Show selected items first
    filtered.sort((a, b) {
      final aOn = _selected.contains(a.value) ? 0 : 1;
      final bOn = _selected.contains(b.value) ? 0 : 1;
      return aOn.compareTo(bOn);
    });

    return AlertDialog(
      title: Text('Edit ${widget.title}', style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 440,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search/add field
            TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: const OutlineInputBorder(),
                hintText: 'Search or type custom (e.g. tcp://9.9.9.9:53)',
                hintStyle: const TextStyle(fontSize: 12),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _filter.isNotEmpty &&
                        !_options.contains(_searchController.text.trim())
                    ? IconButton(
                        icon: const Icon(Icons.add_circle, size: 20),
                        tooltip: 'Add as custom server',
                        onPressed: _addCustom,
                      )
                    : null,
              ),
              onSubmitted: (_) {
                if (_filter.isNotEmpty && !_options.contains(_filter)) {
                  _addCustom();
                }
              },
            ),
            const SizedBox(height: 6),
            Text(
              '${_selected.length} selected ┬╖ tap to toggle',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            // Scrollable list
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (ctx, i) {
                  final opt = filtered[i];
                  final isOn = _selected.contains(opt.value);
                  return CheckboxListTile(
                    dense: true,
                    value: isOn,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(opt.value);
                        } else {
                          _selected.remove(opt.value);
                        }
                      });
                    },
                    title: Text(opt.label, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(opt.description,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: opt.description == 'Custom server' ? 'monospace' : null,
                          color: Colors.grey.shade600,
                        )),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: TText('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: TText('Save'),
        ),
      ],
    );
  }
}

/// Simple multi-select dialog for network interfaces (load balancing).
class _InterfacePickerDialog extends StatefulWidget {
  final List<String> allInterfaces;
  final List<String> initialSelected;

  const _InterfacePickerDialog({
    required this.allInterfaces,
    required this.initialSelected,
  });

  @override
  State<_InterfacePickerDialog> createState() => _InterfacePickerDialogState();
}

class _InterfacePickerDialogState extends State<_InterfacePickerDialog> {
  late Set<String> _selected;

  /// Filter already done on Go side — only Up interfaces with IPv4 are returned.
  List<String> get _usableInterfaces => widget.allInterfaces;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final ifaces = _usableInterfaces;
    return AlertDialog(
      title: TText('Balance Interfaces', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 320,
        child: ifaces.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: TText('No physical interfaces found.',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_selected.length} selected · pick 2 or more',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: ifaces.map((iface) {
                          // Show friendly name prominently, raw name as subtitle
                          final hasParen = iface.contains('(');
                          final friendly = hasParen
                              ? iface.substring(0, iface.lastIndexOf('(')).trim()
                              : iface;
                          final raw = hasParen
                              ? iface.split('(').last.replaceAll(')', '').trim()
                              : iface;
                          return CheckboxListTile(
                            dense: true,
                            value: _selected.contains(iface),
                            title: Text(
                              friendly.isNotEmpty ? friendly : raw,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: friendly.isNotEmpty && friendly != raw
                                ? Text(raw,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500))
                                : null,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(iface);
                              } else {
                                _selected.remove(iface);
                              }
                            }),
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: TText('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.length < 2
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: TText('Save'),
        ),
      ],
    );
  }
}

/// Data class for a network tool button.
class _NetworkTool {
  final IconData icon;
  final String label;
  final String description;
  final Color color;
  final bool requiresRestart;
  final VoidCallback onRun;

  const _NetworkTool({
    required this.icon,
    required this.label,
    required this.description,
    required this.color,
    required this.onRun,
    this.requiresRestart = false,
  });
}
