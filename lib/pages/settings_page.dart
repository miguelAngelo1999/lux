import 'dart:io';

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
    final controller = TextEditingController(text: current.join('\n'));
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit $title', style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 400,
          height: 200,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'One server per line. Supported prefixes: tcp://, https://, dhcp://, udp://, system://',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                    hintText: 'tcp://8.8.8.8:53\nhttps://dns.google/dns-query',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final lines = controller.text
                  .split('\n')
                  .map((l) => l.trim())
                  .where((l) => l.isNotEmpty)
                  .toList();
              Navigator.of(ctx).pop(lines);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
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
