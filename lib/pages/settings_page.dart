import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/model/app.dart';
import 'package:lux/util/utils.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

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

  // DNS server lists (loaded from raw config)
  List<String> _dnsRemote = [];
  List<String> _dnsLocal = [];
  List<String> _dnsBoost = [];

  // SSL Inspection state
  SslInspectionSettings? _sslSettings;
  List<InspectionListEntry> _inspectionList = [];
  List<String> _bypassList = [];
  bool _sslLoading = false;

  // Proxy detection state
  ProxyDetectResult? _proxyDetectResult;
  bool _proxyDetecting = false;

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

    // Load SSL inspection state (silently — backend may not support yet)
    try {
      final ssl = await widget.coreManager.getSslInspectionSettings();
      final list = await widget.coreManager.getInspectionList();
      final bypass = await widget.coreManager.getBypassList();
      if (mounted) setState(() {
        _sslSettings = ssl;
        _inspectionList = list;
        _bypassList = bypass;
      });
    } catch (_) {}
  }

  Future<void> _save(Setting updated) async {
    setState(() => _isSaving = true);
    try {
      await widget.coreManager.saveSetting(updated);
      if (mounted) setState(() => _setting = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _setting == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final s = _setting!;
    final isTun = s.mode == ProxyMode.tun || s.mode == ProxyMode.mixed;

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── General ──
            _sectionHeader('General'),
            _dropdownTile<String>(
              'Language',
              _currentLanguage(),
              ['system', 'en', 'zh-CN'],
              (v) => _languageLabel(v),
              (v) => _saveLanguage(v),
            ),
            _dropdownTile<String>(
              'Theme',
              _currentTheme(),
              ['system', 'dark', 'light'],
              (v) => _themeLabel(v),
              (v) => _saveTheme(v),
            ),
            _switchTile(
              'Auto Launch',
              'Start Lux when you log in',
              s.autoLaunch,
              (v) => _save(s.copyWith(autoLaunch: v)),
            ),
            _switchTile(
              'Auto Connect',
              'Connect proxy when Lux opens',
              s.autoConnect,
              (v) => _save(s.copyWith(autoConnect: v)),
            ),
            _switchTile(
              'Sensitive Info Mode',
              'Hide IP addresses and proxy names in UI',
              s.sensitiveInfoMode ?? false,
              (v) => _save(s.copyWith(sensitiveInfoMode: v)),
            ),

            // ── Network ──
            const SizedBox(height: 16),
            _sectionHeader('Network'),
            _dropdownTile<ProxyMode>(
              'Proxy Mode',
              s.mode,
              [ProxyMode.system, ProxyMode.tun, ProxyMode.mixed],
              (v) => getModeLabel(v),
              (v) => _save(s.copyWith(mode: v)),
            ),
            _dropdownTile<String>(
              'Default Interface',
              s.defaultInterface.isEmpty ? '' : s.defaultInterface,
              ['', ..._interfaces],
              (v) => v.isEmpty ? 'Auto' : v,
              (v) => _save(s.copyWith(defaultInterface: v)),
            ),
            _numberTile(
              'Local Server Port',
              s.localServerPort,
              (v) => _save(s.copyWith(localServerPort: v)),
            ),
            _switchTile(
              'Allow LAN',
              'Allow other devices to connect via LAN',
              s.allowLan,
              (v) => _save(s.copyWith(allowLan: v)),
            ),

            // ── TUN/Mixed only ──
            if (isTun) ...[
              const SizedBox(height: 16),
              _sectionHeader('TUN / Mixed Mode'),
              _switchTile(
                'Block QUIC',
                'Disable HTTP/3 (fixes YouTube and some sites)',
                s.blockQuic ?? false,
                (v) => _save(s.copyWith(blockQuic: v)),
              ),
              _switchTile(
                'Find Process',
                'Identify which app made each connection (shows in Connections)',
                s.shouldFindProcess ?? false,
                (v) => _save(s.copyWith(shouldFindProcess: v)),
              ),
              _switchTile(
                'Fake IP',
                'Forward DNS queries to proxy for better performance',
                s.fakeIp ?? false,
                (v) => _save(s.copyWith(fakeIp: v)),
              ),

              // ── DNS Servers ──
              const SizedBox(height: 8),
              if (s.fakeIp != true)
                _dnsListTile('Remote DNS', 'Resolve foreign domains', _dnsRemote,
                    (v) => _saveDnsList('remote', v)),
              _dnsListTile('Local DNS', 'Resolve domestic domains', _dnsLocal,
                  (v) => _saveDnsList('local', v)),
              _dnsListTile('Boost DNS', 'Initial bootstrap resolution', _dnsBoost,
                  (v) => _saveDnsList('boost', v)),
              const SizedBox(height: 8),

              _switchTile(
                'Disable DNS Cache',
                'Always get latest DNS responses',
                s.disableDnsCache ?? false,
                (v) => _save(s.copyWith(disableDnsCache: v)),
              ),
              _switchTile(
                'Hijack DNS',
                'Modify system DNS to route through Lux',
                s.hijackDns,
                (v) => _save(s.copyWith(hijackDns: v)),
              ),
            ],

            // ── Network Detection ──
            const SizedBox(height: 16),
            _sectionHeader('Network Detection'),
            _buildProxyDetectSection(),

            // ── Auto Mode ──
            const SizedBox(height: 16),
            _sectionHeader('Auto Mode'),
            _switchTile(
              'Enable Auto Mode',
              'Automatically test proxies and select the best one',
              s.autoModeEnabled,
              (v) => _save(s.copyWith(autoModeEnabled: v)),
            ),
            if (s.autoModeEnabled) ...[
              _dropdownTile<String>(
                'Auto Mode Type',
                s.autoModeType.isEmpty ? 'fallback' : s.autoModeType,
                ['fallback', 'url-test'],
                (v) => v == 'fallback' ? 'Fallback' : 'URL Test (fastest)',
                (v) => _save(s.copyWith(autoModeType: v)),
              ),
              _textFieldTile(
                'Test URL',
                s.autoModeUrl,
                'https://google.com',
                (v) => _save(s.copyWith(autoModeUrl: v)),
              ),
            ],

            const SizedBox(height: 16),
            _sectionHeader('Advanced'),
            _configFileTile(),

            // ── SSL Inspection ──
            const SizedBox(height: 16),
            _sectionHeader('SSL Inspection (Lux MITM)'),
            _buildSslInspectionSection(),

            const SizedBox(height: 32),
          ],
        ),
        if (_isSaving)
          const Positioned(
            top: 8,
            right: 8,
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  // ── DNS editing helpers ──────────────────────────────────────────────────

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
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
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

  // ── Language / Theme helpers ─────────────────────────────────────────────

  String _currentLanguage() {
    final appState = Provider.of<AppStateModel>(context, listen: false);
    final locale = appState.locale;
    if (locale.languageCode == 'zh') return 'zh-CN';
    if (locale.languageCode == 'en') return 'en';
    return 'system';
  }

  String _languageLabel(String v) {
    switch (v) {
      case 'en': return 'English';
      case 'zh-CN': return '中文';
      default: return 'System';
    }
  }

  Future<void> _saveLanguage(String v) async {
    final appState = Provider.of<AppStateModel>(context, listen: false);
    appState.updateLocale(convertLocale(v));
    // Persist via the backend setting API
    try {
      final current = await widget.coreManager.dio.get(
          'http://${widget.coreManager.baseUrl}/setting');
      final raw = Map<String, dynamic>.from(current.data['setting'] as Map);
      raw['language'] = v;
      await widget.coreManager.dio.put(
          'http://${widget.coreManager.baseUrl}/setting', data: raw);
    } catch (e) {
      debugPrint('Failed to save language: $e');
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
    appState.updateTheme(convertTheme(v));
    try {
      final current = await widget.coreManager.dio.get(
          'http://${widget.coreManager.baseUrl}/setting');
      final raw = Map<String, dynamic>.from(current.data['setting'] as Map);
      raw['theme'] = v;
      await widget.coreManager.dio.put(
          'http://${widget.coreManager.baseUrl}/setting', data: raw);
    } catch (e) {
      debugPrint('Failed to save theme: $e');
    }
  }

  // ── Config File tile ────────────────────────────────────────────────────────

  Widget _configFileTile() {
    return ListTile(
      dense: true,
      title: const Text('Config File', style: TextStyle(fontSize: 14)),
      subtitle: const Text('Open or reset your configuration', style: TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () async {
              final homeDir = await getHomeDir();
              launchUrl(Uri.file(homeDir));
            },
            child: const Text('Open Dir', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: _isSaving ? null : () => _confirmResetConfig(),
            child: const Text('Reset', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmResetConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Configuration'),
        content: const Text(
          'This will reset all settings to defaults. The app will restart. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
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
          const SnackBar(content: Text('Config reset. Restart the app.')),
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

  // ── SSL Inspection ─────────────────────────────────────────────────────────

  Widget _buildSslInspectionSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        title: const Text('SSL Inspection', style: TextStyle(fontSize: 14)),
        subtitle: const Text('Decrypt HTTPS for selected domains only', style: TextStyle(fontSize: 12)),
        value: _sslSettings?.enabled ?? false,
        dense: true,
        onChanged: (_isSaving || _sslLoading) ? null : (v) => _toggleSslInspection(v),
      ),
      if (_sslSettings?.enabled == true && _sslSettings?.caFingerprint != null) ...[
        ListTile(
          dense: true,
          title: const Text('Root CA', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            'SHA256: ${_sslSettings!.caFingerprint!.substring(0, 16)}...\n'
            'Generated: ${_sslSettings!.caGeneratedAt?.toLocal().toString().split(".").first ?? "unknown"}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.download, size: 14),
              label: const Text('Export CA', style: TextStyle(fontSize: 12)),
              onPressed: _exportCA,
            ),
            if (Platform.isWindows)
              OutlinedButton.icon(
                icon: const Icon(Icons.verified_user_outlined, size: 14),
                label: const Text('Install in Trust Store', style: TextStyle(fontSize: 12)),
                onPressed: _installCAWindows,
              ),
          ]),
        ),
      ],
      if (_sslSettings?.enabled == true) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Inspected Domains', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        ..._inspectionList.map((entry) => ListTile(
          dense: true,
          leading: Icon(entry.enabled ? Icons.circle : Icons.circle_outlined, size: 10,
              color: entry.enabled ? Colors.green : Colors.grey),
          title: Text(entry.pattern, style: const TextStyle(fontSize: 13)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: Icon(entry.enabled ? Icons.toggle_on : Icons.toggle_off, size: 20),
                onPressed: () => _toggleDomain(entry.pattern), padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
            IconButton(icon: const Icon(Icons.close, size: 14, color: Colors.red),
                onPressed: () => _removeDomain(entry.pattern), padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
          ]),
        )),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: _AddDomainRow(onAdd: _addDomain),
        ),
        TextButton(
          onPressed: _showBypassList,
          child: const Text('View bypass list (read-only)', style: TextStyle(fontSize: 12)),
        ),
      ],
    ]);
  }

  Future<void> _toggleSslInspection(bool v) async {
    if (v && _sslSettings?.caFingerprint == null) {
      final confirmed = await showDialog<bool>(context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Enable SSL Inspection?'),
          content: const Text('SSL Inspection decrypts HTTPS traffic for the domains you select. '
              'You must install the Lux Root CA certificate into your system trust store. '
              'You are responsible for the security implications.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enable')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    setState(() => _sslLoading = true);
    try {
      await widget.coreManager.setSslInspectionEnabled(v);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _sslLoading = false);
    }
  }

  Future<void> _exportCA() async {
    try {
      final bytes = await widget.coreManager.getCACertPem();
      final tmp = File('${Directory.systemTemp.path}/lux-ca.crt');
      await tmp.writeAsBytes(bytes);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to ${tmp.path}')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _installCAWindows() async {
    try {
      final bytes = await widget.coreManager.getCACertPem();
      // Use a path without spaces for certutil compatibility
      final tmp = File('C:\\Windows\\Temp\\lux-ca-install.crt');
      await tmp.writeAsBytes(bytes);
      // certutil -addstore Root requires elevation — run via PowerShell RunAs
      final result = await Process.run(
        'powershell.exe',
        [
          '-noprofile',
          '-command',
          'Start-Process certutil -ArgumentList @("-addstore","Root","C:\\Windows\\Temp\\lux-ca-install.crt") -Verb RunAs -Wait -WindowStyle Hidden',
        ],
        runInShell: false,
      );
      try { await tmp.delete(); } catch (_) {}
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.exitCode == 0
              ? 'Lux CA installed in Windows trust store ✓'
              : 'Install returned exit ${result.exitCode} — check if you approved the UAC prompt')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Install failed: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _addDomain(String pattern) async {
    try {
      await widget.coreManager.addInspectionDomain(pattern);
      final l = await widget.coreManager.getInspectionList();
      if (mounted) setState(() => _inspectionList = l);
    } catch (_) {}
  }

  Future<void> _toggleDomain(String pattern) async {
    try {
      await widget.coreManager.toggleInspectionDomain(pattern);
      final l = await widget.coreManager.getInspectionList();
      if (mounted) setState(() => _inspectionList = l);
    } catch (_) {}
  }

  Future<void> _removeDomain(String pattern) async {
    try {
      await widget.coreManager.removeInspectionDomain(pattern);
      final l = await widget.coreManager.getInspectionList();
      if (mounted) setState(() => _inspectionList = l);
    } catch (_) {}
  }

  void _showBypassList() {
    showModalBottomSheet(context: context, builder: (ctx) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Bypass List (never inspected)', style: Theme.of(ctx).textTheme.titleSmall),
        const SizedBox(height: 8),
        ..._bypassList.map((p) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(p, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        )),
      ],
    ));
  }

  // ── Proxy Detection ─────────────────────────────────────────────────────────

  Widget _buildProxyDetectSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          title: const Text('Detect Upstream Proxy', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            'Check if your network uses a corporate proxy or PAC/WPAD auto-config',
            style: TextStyle(fontSize: 12),
          ),
          trailing: _proxyDetecting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : OutlinedButton.icon(
                  icon: const Icon(Icons.search, size: 14),
                  label: const Text('Detect', style: TextStyle(fontSize: 12)),
                  onPressed: _runProxyDetect,
                ),
        ),
        if (_proxyDetectResult != null) ..._buildDetectResults(),
      ],
    );
  }

  List<Widget> _buildDetectResults() {
    final result = _proxyDetectResult!;
    if (result.error != null && result.error!.isNotEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Detection error: ${result.error}',
              style: const TextStyle(fontSize: 12, color: Colors.red)),
        ),
      ];
    }
    if (!result.detected || result.proxies.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('No upstream proxy detected on this network.',
              style: TextStyle(fontSize: 12, color: Colors.green)),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(
          '${result.proxies.length} upstream proxy detected:',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      ...result.proxies.map((p) => _buildDetectedProxyTile(p)),
    ];
  }

  Widget _buildDetectedProxyTile(DetectedProxy p) {
    final hasError = p.error != null && p.error!.isNotEmpty;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                hasError ? Icons.warning_amber : Icons.shield_outlined,
                size: 16,
                color: hasError ? Colors.orange : Colors.blue,
              ),
              const SizedBox(width: 6),
              Text(
                p.host.isNotEmpty ? '${p.host}:${p.port}' : 'PAC only',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              _sourceChip(p.source),
            ]),
            if (p.pacUrl != null && p.pacUrl!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('PAC: ${p.pacUrl}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis),
            ],
            if (p.requiresAuth) ...[
              const SizedBox(height: 4),
              const Row(children: [
                Icon(Icons.lock_outline, size: 13, color: Colors.orange),
                SizedBox(width: 4),
                Text('Requires proxy authentication (407)',
                    style: TextStyle(fontSize: 12, color: Colors.orange)),
              ]),
            ],
            if (hasError) ...[
              const SizedBox(height: 4),
              Text(p.error!,
                  style: const TextStyle(fontSize: 11, color: Colors.red)),
            ],
            // Only show "Add as proxy" if we have a concrete host:port
            if (p.host.isNotEmpty && p.port.isNotEmpty && !hasError) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 13),
                  label: const Text('Add as HTTP proxy', style: TextStyle(fontSize: 12)),
                  onPressed: () => _addDetectedProxyAsEntry(p),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(String source) {
    final labels = {
      'dhcp_option252': 'DHCP opt-252',
      'wpad_dns': 'WPAD DNS',
      'pac': 'PAC',
      'manual': 'Manual',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        labels[source] ?? source,
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Future<void> _runProxyDetect() async {
    setState(() {
      _proxyDetecting = true;
      _proxyDetectResult = null;
    });
    try {
      final result = await widget.coreManager.detectNetworkProxy();
      if (mounted) setState(() => _proxyDetectResult = result);
    } catch (e) {
      if (mounted) {
        setState(() => _proxyDetectResult =
            ProxyDetectResult(detected: false, proxies: [], error: e.toString()));
      }
    } finally {
      if (mounted) setState(() => _proxyDetecting = false);
    }
  }

  Future<void> _addDetectedProxyAsEntry(DetectedProxy p) async {
    final nameCtrl = TextEditingController(text: '${p.host}:${p.port}');
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Detected Proxy'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            if (p.requiresAuth) ...[
              TextField(
                controller: usernameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: passwordCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  isDense: true,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final port = int.tryParse(p.port) ?? 0;
      final proxyData = <String, dynamic>{
        'name': nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : '${p.host}:${p.port}',
        'type': 'http',
        'server': p.host,
        'port': port,
        if (p.requiresAuth && usernameCtrl.text.isNotEmpty)
          'username': usernameCtrl.text,
        if (p.requiresAuth && passwordCtrl.text.isNotEmpty)
          'password': passwordCtrl.text,
      };
      await widget.coreManager.addProxy(proxyData);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Proxy added ✓')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add proxy: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      nameCtrl.dispose();
      usernameCtrl.dispose();
      passwordCtrl.dispose();
    }
  }

  // ── Section header ──────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _switchTile(
      String title, String subtitle, bool value, void Function(bool) onChanged) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: value,
      dense: true,
      onChanged: _isSaving ? null : onChanged,
    );
  }

  Widget _dropdownTile<T>(String title, T value, List<T> options,
      String Function(T) label, void Function(T) onChanged) {
    return ListTile(
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 14)),
      trailing: DropdownButton<T>(
        value: value,
        items: options
            .map((o) => DropdownMenuItem(value: o, child: Text(label(o), style: const TextStyle(fontSize: 13))))
            .toList(),
        onChanged: _isSaving ? null : (v) { if (v != null) onChanged(v); },
        underline: const SizedBox(),
      ),
    );
  }

  Widget _numberTile(String title, int value, void Function(int) onChanged) {
    return ListTile(
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 14)),
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

  Widget _textFieldTile(String title, String value, String hint,
      void Function(String) onChanged) {
    return ListTile(
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 14)),
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

// ── Add Domain Row ────────────────────────────────────────────────────────────

class _AddDomainRow extends StatefulWidget {
  final void Function(String) onAdd;
  const _AddDomainRow({required this.onAdd});
  @override State<_AddDomainRow> createState() => _AddDomainRowState();
}
class _AddDomainRowState extends State<_AddDomainRow> {
  final _ctrl = TextEditingController();
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Row(children: [
    Expanded(child: TextField(controller: _ctrl,
      decoration: const InputDecoration(hintText: 'example.com or *.example.com',
          isDense: true, border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
      style: const TextStyle(fontSize: 12),
      onSubmitted: (v) { if (v.isNotEmpty) { widget.onAdd(v); _ctrl.clear(); } },
    )),
    const SizedBox(width: 8),
    FilledButton(
      onPressed: () { if (_ctrl.text.isNotEmpty) { widget.onAdd(_ctrl.text); _ctrl.clear(); } },
      child: const Text('Add', style: TextStyle(fontSize: 12)),
    ),
  ]);
}

// ── DNS Picker Dialog ─────────────────────────────────────────────────────────

class _DnsOption {
  final String value;
  final String label;
  final String description;

  const _DnsOption(this.value, this.label, this.description);
}

const _allDnsOptions = <_DnsOption>[
  _DnsOption('tcp://8.8.8.8:53', 'Google DNS', 'TCP · 8.8.8.8:53 · Fast, global'),
  _DnsOption('tcp://1.1.1.1:53', 'Cloudflare DNS', 'TCP · 1.1.1.1:53 · Privacy-focused'),
  _DnsOption('tcp://114.114.114.114:53', '114 DNS', 'TCP · 114.114.114.114:53 · China mainland'),
  _DnsOption('tcp://119.29.29.29:53', 'DNSPod', 'TCP · 119.29.29.29:53 · Tencent China'),
  _DnsOption('tcp://223.5.5.5:53', 'AliDNS', 'TCP · 223.5.5.5:53 · Alibaba China'),
  _DnsOption('https://dns.google/dns-query', 'Google DoH', 'HTTPS · Encrypted DNS-over-HTTPS'),
  _DnsOption('https://cloudflare-dns.com/dns-query', 'Cloudflare DoH', 'HTTPS · Encrypted DNS-over-HTTPS'),
  _DnsOption('https://doh.pub/dns-query', 'DNSPod DoH', 'HTTPS · Tencent encrypted DNS (China)'),
  _DnsOption('dhcp://auto', 'DHCP Auto', 'Uses DNS from your router/DHCP server'),
  _DnsOption('system://auto', 'System Auto', 'Uses your OS-configured DNS servers'),
  _DnsOption('udp://8.8.8.8:53', 'Google UDP', 'UDP · 8.8.8.8:53 · Traditional DNS'),
  _DnsOption('udp://1.1.1.1:53', 'Cloudflare UDP', 'UDP · 1.1.1.1:53 · Traditional DNS'),
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
              '${_selected.length} selected · tap to toggle',
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
