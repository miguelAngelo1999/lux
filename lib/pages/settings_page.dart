import 'dart:convert';
import 'dart:io';
import 'package:lux/util/cert_installer.dart';

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
  // SSL inspection state
  SslBumpStatus? _sslStatus;
  bool _sslChecking = false;
  bool _sslInstalling = false;
  InstallResult? _installResult;

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
          Text('Elevation required'),
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restart & Apply'),
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
            // ΓöÇΓöÇ General ΓöÇΓöÇ
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
            _resetDismissedProxiesTile(),

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

            // ΓöÇΓöÇ TUN/Mixed only ΓöÇΓöÇ
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

              // ΓöÇΓöÇ DNS Servers ΓöÇΓöÇ
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

            // ΓöÇΓöÇ Auto Mode ΓöÇΓöÇ
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

            // ΓöÇΓöÇ SSL Inspection ΓöÇΓöÇ
            const SizedBox(height: 16),
            _sectionHeader('SSL Inspection'),
            _sslInspectionSection(),

            // ΓöÇΓöÇ Config Backup ΓöÇΓöÇ
            const SizedBox(height: 16),
            _sectionHeader('Config Backup'),
            _importExportTile(),

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

  // ΓöÇΓöÇ Language / Theme helpers ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

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
      case 'zh-CN': return 'Σ╕¡µûç';
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

  // ΓöÇΓöÇ Config File tile ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  // ΓöÇΓöÇ Config Import / Export ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  Widget _importExportTile() {
    return ListTile(
      dense: true,
      title: const Text('Backup & Restore', style: TextStyle(fontSize: 14)),
      subtitle: const Text('Export or import your full configuration', style: TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: _isSaving ? null : _exportConfig,
            child: const Text('Export', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: _isSaving ? null : _importConfig,
            child: const Text('Import', style: TextStyle(fontSize: 12)),
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
          const SnackBar(content: Text('config.json not found')));
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
            title: const Text('Import Config'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Path to config.json',
                hintText: '/Users/.../lux-config-backup.json',
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Open')),
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
          const SnackBar(content: Text('Invalid JSON'), backgroundColor: Colors.red));
        return;
      }
      if (!parsed.containsKey('setting') && !parsed.containsKey('proxy')) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not a valid Lux config'), backgroundColor: Colors.red));
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import Config'),
          content: const Text('Replaces current config. Restart to apply. Continue?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Import'),
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
        const SnackBar(content: Text('Imported. Restart Lux to apply.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e'), backgroundColor: Colors.red));
    }
  }

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
            const SnackBar(content: Text('No certificate available to install')),
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
                Flexible(child: Text('Trust this certificate?', style: TextStyle(fontSize: 16))),
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
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('I trust this — install'),
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
          Text('Intercepting CA',
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
          Text('Checking…', style: TextStyle(fontSize: 12)),
        ],
      );
    } else if (status == null) {
      statusChip = const Text('Not checked yet', style: TextStyle(fontSize: 12, color: Colors.grey));
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
          Text('SSL inspection detected',
              style: TextStyle(fontSize: 12, color: Colors.amber.shade700, fontWeight: FontWeight.w600)),
        ],
      );
    } else {
      statusChip = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
          SizedBox(width: 4),
          Text('No interception detected', style: TextStyle(fontSize: 12, color: Colors.green)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          dense: true,
          title: const Text('Detect SSL Bumping', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            'Check if your proxy intercepts HTTPS traffic and install its CA certificate so curl, git, npm, and Python trust it.',
            style: TextStyle(fontSize: 12),
          ),
          trailing: TextButton.icon(
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Check', style: TextStyle(fontSize: 12)),
            onPressed: _sslChecking ? null : _checkSslBump,
          ),
        ),
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
                    : 'Installs into macOS System Keychain (all users), curl, git, Homebrew openssl, Node.js, and Python certifi.',
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

  Widget _resetDismissedProxiesTile() {
    return ListTile(
      dense: true,
      title: const Text('Proxy Detection', style: TextStyle(fontSize: 14)),
      subtitle: const Text('Re-show startup proxy detection dialogs',
          style: TextStyle(fontSize: 12)),
      trailing: TextButton(
        onPressed: () async {
          await clearDismissedProxies();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Proxy detection dialogs will show again on next launch'),
                duration: Duration(seconds: 3),
              ),
            );
          }
        },
        child: const Text('Reset', style: TextStyle(fontSize: 12)),
      ),
    );
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
