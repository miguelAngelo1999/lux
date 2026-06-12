import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
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
      if (mounted) {
        setState(() {
          _setting = setting;
          _interfaces = ifaces;
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
