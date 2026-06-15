import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/cert_installer.dart';
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

  // SSL inspection state
  SslBumpStatus? _sslStatus;
  bool _sslChecking = false;
  bool _sslInstalling = false;
  InstallResult? _installResult;

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

  Future<void> _checkSslBump() async {
    setState(() {
      _sslChecking = true;
      _installResult = null;
    });
    try {
      final status = await widget.coreManager.getSslBumpStatus();
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

            // ── SSL Inspection ──
            const SizedBox(height: 16),
            _sectionHeader('SSL Inspection'),
            _sslInspectionSection(),

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

  // ── SSL Inspection section widget ──────────────────────────────────────────

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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                icon: _sslInstalling
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.verified_user, size: 16),
                label: Text(
                  _sslInstalling ? 'Installing…' : 'Install Certificate',
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
            ? Colors.green.shade50.withOpacity(0.3)
            : Colors.orange.shade50.withOpacity(0.3),
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
