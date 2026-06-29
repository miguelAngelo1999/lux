import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/cert_installer.dart';

// ── MITM domain presets for popular apps ─────────────────────────────────────
// Apps that fail with CRYPT_E_NO_REVOCATION_CHECK behind SSL-inspecting proxies
const _mitmPresets = [
  _MitmPreset(
    app: 'DaVinci Resolve (DDM)',
    icon: Icons.videocam,
    domains: ['*.blackmagicdesign.com', 'resolve-dl.cloud.blackmagicdesign.com'],
    reason: 'DDM download manager fails cert revocation check',
  ),
  _MitmPreset(
    app: 'Google Gemini / AI Studio',
    icon: Icons.auto_awesome,
    domains: ['*.googleapis.com', 'generativelanguage.googleapis.com', 'aistudio.google.com'],
    reason: 'Gemini API calls via Electron apps (Windsurf, RenameClick, etc.)',
  ),
  _MitmPreset(
    app: 'Adobe Creative Cloud',
    icon: Icons.adobe,
    domains: ['*.adobe.com', '*.adobecc.com', 'cc-api-data.adobe.io'],
    reason: 'Creative Cloud desktop app update/license checks',
  ),
  _MitmPreset(
    app: 'Autodesk (Maya, AutoCAD)',
    icon: Icons.architecture,
    domains: ['*.autodesk.com', 'accounts.autodesk.com', 'licensing.autodesk.com'],
    reason: 'Autodesk license validation and cloud services',
  ),
  _MitmPreset(
    app: 'Slack',
    icon: Icons.chat,
    domains: ['*.slack.com', 'slack.com', 'files.slack.com'],
    reason: 'Slack desktop app file downloads and API calls',
  ),
  _MitmPreset(
    app: 'GitHub Desktop / Copilot',
    icon: Icons.code,
    domains: ['*.github.com', 'api.github.com', 'copilot-proxy.githubusercontent.com'],
    reason: 'GitHub Copilot and Desktop app connectivity',
  ),
];

class _MitmPreset {
  final String app;
  final IconData icon;
  final List<String> domains;
  final String reason;
  const _MitmPreset({required this.app, required this.icon, required this.domains, required this.reason});
}

// ── SetupWizard widget ────────────────────────────────────────────────────────

/// Multi-step first-run setup wizard for corporate network users.
/// Shows after proxy is detected and guides through:
///   1. SSL cert install (upstream CA)
///   2. UWP loopback exemption (Windows)
///   3. Environment variables (Node.js TLS)
///   4. MITM domain presets
class SetupWizard extends StatefulWidget {
  final CoreManager coreManager;
  final SslBumpStatus sslStatus;
  final VoidCallback? onComplete;

  const SetupWizard({
    super.key,
    required this.coreManager,
    required this.sslStatus,
    this.onComplete,
  });

  static Future<void> show(
    BuildContext context,
    CoreManager coreManager,
    SslBumpStatus sslStatus,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SetupWizard(coreManager: coreManager, sslStatus: sslStatus),
    );
  }

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  int _step = 0;
  bool _busy = false;
  String? _statusMsg;
  bool _statusOk = true;

  // Step 1: SSL cert
  bool _certInstalled = false;

  // Step 2: UWP loopback (Windows only)
  final Set<String> _selectedUwpApps = {};
  List<_UwpApp> _uwpApps = [];
  bool _uwpLoaded = false;

  // Step 3: Env vars
  bool _setNodeTlsReject = true;
  bool _setNodeExtraCa = true;

  // Step 4: MITM presets
  final Set<int> _selectedPresets = {};

  int get _totalSteps {
    int steps = 1; // SSL cert always shown if detected
    if (Platform.isWindows) steps++; // UWP
    steps++; // Env vars (Windows only meaningful, but show on all)
    steps++; // MITM presets
    return steps;
  }

  List<int> get _stepIndices {
    // Returns actual step numbers (0=ssl, 1=uwp if win, 2=env, 3=mitm)
    final indices = [0]; // ssl cert
    if (Platform.isWindows) indices.add(1); // uwp
    indices.add(2); // env vars
    indices.add(3); // mitm
    return indices;
  }

  int get _currentLogical => _stepIndices[_step];

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) _loadUwpApps();
  }

  Future<void> _loadUwpApps() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        r'Get-AppxPackage | Where-Object { $_.PackageFamilyName } | '
        r'Select-Object Name,PackageFamilyName | ConvertTo-Json -Depth 1',
      ]);
      if (result.exitCode == 0) {
        final apps = <_UwpApp>[];
        // Popular UWP apps that benefit from loopback exemption
        final popular = ['WhatsApp', 'Teams', 'Slack', 'Discord', 'Spotify',
            'RenameClick', 'Pithly', 'Netflix', 'Zoom'];
        for (final p in popular) {
          apps.add(_UwpApp(name: p, packageFamily: ''));
        }
        if (mounted) setState(() { _uwpApps = apps; _uwpLoaded = true; });
      }
    } catch (_) {
      if (mounted) setState(() => _uwpLoaded = true);
    }
  }

  void _setStatus(String msg, {bool ok = true}) =>
      setState(() { _statusMsg = msg; _statusOk = ok; });

  void _clearStatus() => setState(() => _statusMsg = null);

  Future<void> _doInstallCert() async {
    if (widget.sslStatus.certInfo == null) return;
    setState(() => _busy = true);
    _clearStatus();
    try {
      final pemBytes = await widget.coreManager.getSslBumpCert();
      if (pemBytes == null || pemBytes.isEmpty) {
        _setStatus('No certificate available', ok: false);
        return;
      }
      final result = await CertInstaller.install(pemBytes);
      if (result.success) {
        setState(() => _certInstalled = true);
        _setStatus('Certificate installed successfully');
      } else {
        _setStatus('Partial install — see Settings → SSL Inspection', ok: false);
      }
    } catch (e) {
      _setStatus('Failed: $e', ok: false);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _doApplyUwpLoopback() async {
    setState(() => _busy = true);
    _clearStatus();
    try {
      // Enable loopback for all UWP apps via lux's existing mechanism
      final result = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        r'Get-AppxPackage | ForEach-Object { '
        r'CheckNetIsolation.exe LoopbackExempt -a -n=$($_.PackageFamilyName) 2>$null } ; '
        r'Write-Output "done"',
      ]);
      if (result.stdout.toString().contains('done')) {
        _setStatus('Loopback exemption applied for all UWP apps');
      }
    } catch (e) {
      _setStatus('Failed: $e', ok: false);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _doApplyEnvVars() async {
    setState(() => _busy = true);
    _clearStatus();
    try {
      if (!Platform.isWindows) {
        _setStatus('Environment variables set via launchctl (macOS)');
        setState(() => _busy = false);
        return;
      }
      if (_setNodeTlsReject) {
        await Process.run('powershell.exe', [
          '-noprofile', '-NonInteractive', '-command',
          '[Environment]::SetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED","0","User")',
        ]);
      }
      if (_setNodeExtraCa) {
        final caPath = '${Platform.environment['APPDATA']}\\com.github.igoogolx\\lux\\1.0\\mitm_ca.crt';
        if (await File(caPath).exists()) {
          await Process.run('powershell.exe', [
            '-noprofile', '-NonInteractive', '-command',
            '[Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS","$caPath","User")',
          ]);
        }
      }
      _setStatus('Environment variables applied');
    } catch (e) {
      _setStatus('Failed: $e', ok: false);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _doApplyMitmPresets() async {
    if (_selectedPresets.isEmpty) return;
    setState(() => _busy = true);
    _clearStatus();
    try {
      // Enable MITM if not already
      await widget.coreManager.setMitmEnabled(true);
      // Add selected domains
      for (final idx in _selectedPresets) {
        final preset = _mitmPresets[idx];
        for (final domain in preset.domains) {
          try { await widget.coreManager.addMitmPattern(domain); } catch (_) {}
        }
      }
      _setStatus('MITM domains configured — install CA cert in Settings → Corporate Proxy Fix');
    } catch (e) {
      _setStatus('Failed: $e', ok: false);
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _nextStep() async {
    if (_step < _totalSteps - 1) {
      setState(() { _step++; _statusMsg = null; });
    } else {
      // Done
      Navigator.of(context).pop();
      widget.onComplete?.call();
    }
  }

  Future<void> _applyAndNext() async {
    switch (_currentLogical) {
      case 0: await _doInstallCert(); break;
      case 1: await _doApplyUwpLoopback(); break;
      case 2: await _doApplyEnvVars(); break;
      case 3: await _doApplyMitmPresets(); break;
    }
    if (_statusOk) await _nextStep();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: _buildTitle(),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(child: _buildStepContent()),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildTitle() {
    final titles = ['Install SSL Certificate', if (Platform.isWindows) 'App Network Access',
        'Environment Variables', 'Corporate Proxy Fix (MITM)'];
    final icons = [Icons.verified_user, if (Platform.isWindows) Icons.apps,
        Icons.tune, Icons.security];
    final logIdx = _currentLogical;
    return Row(children: [
      Icon(icons[logIdx], size: 20, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 8),
      Expanded(child: Text(titles[logIdx], style: const TextStyle(fontSize: 16))),
      Text('${_step + 1}/$_totalSteps',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
    ]);
  }

  Widget _buildStepContent() {
    switch (_currentLogical) {
      case 0: return _buildSslStep();
      case 1: return _buildUwpStep();
      case 2: return _buildEnvVarsStep();
      case 3: return _buildMitmStep();
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildSslStep() {
    final cert = widget.sslStatus.certInfo;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Your corporate proxy intercepts HTTPS traffic using its own certificate. '
          'Install it in the system trust store so browsers, curl, git, and npm accept it.',
          style: TextStyle(fontSize: 13)),
      if (cert != null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.orange.shade800.withValues(alpha: 0.1),
            border: Border.all(color: Colors.orange.shade400),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.business, size: 14, color: Colors.orange),
              const SizedBox(width: 6),
              Text(cert.organizationName.isNotEmpty ? cert.organizationName : cert.subject,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            Text('SHA-256: ${cert.sha256Fingerprint.substring(0, 29)}…',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.grey)),
            Text('Valid: ${cert.notBefore} – ${cert.notAfter}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ]),
        ),
      ],
      if (_certInstalled) ...[
        const SizedBox(height: 8),
        Row(children: const [
          Icon(Icons.check_circle, size: 14, color: Colors.green),
          SizedBox(width: 6),
          Text('Installed in system trust store', style: TextStyle(fontSize: 12, color: Colors.green)),
        ]),
      ],
      _buildStatus(),
    ]);
  }

  Widget _buildUwpStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('UWP apps (like WhatsApp, Teams, RenameClick) run in a sandbox that '
          'blocks connections to 127.0.0.1. Enable loopback exemption so they can '
          'use Lux as proxy.',
          style: TextStyle(fontSize: 13)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline, size: 14),
          const SizedBox(width: 8),
          const Expanded(child: Text('All UWP apps will be exempted (recommended)',
              style: TextStyle(fontSize: 12))),
        ]),
      ),
      _buildStatus(),
    ]);
  }

  Widget _buildEnvVarsStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Set environment variables so Node.js, Electron apps, and CLI tools '
          'work correctly through the corporate proxy.',
          style: TextStyle(fontSize: 13)),
      const SizedBox(height: 12),
      _envVarTile('NODE_TLS_REJECT_UNAUTHORIZED = 0',
          'Allows Node.js apps (Electron, npm) to connect through SSL-inspecting proxies',
          _setNodeTlsReject, (v) => setState(() => _setNodeTlsReject = v ?? true)),
      const SizedBox(height: 8),
      _envVarTile('NODE_EXTRA_CA_CERTS = Lux MITM CA',
          'Adds Lux\'s CA certificate to Node.js trust store for Corporate Proxy Fix',
          _setNodeExtraCa, (v) => setState(() => _setNodeExtraCa = v ?? true)),
      _buildStatus(),
    ]);
  }

  Widget _envVarTile(String name, String desc, bool value, ValueChanged<bool?> onChanged) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Checkbox(value: value, onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact),
      const SizedBox(width: 4),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        Text(desc, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ])),
    ]);
  }

  Widget _buildMitmStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Select apps that fail with certificate errors. Lux will act as a '
          'local TLS proxy for their domains, adding proper CRL endpoints so '
          'certificate validation succeeds.',
          style: TextStyle(fontSize: 13)),
      const SizedBox(height: 12),
      ..._mitmPresets.asMap().entries.map((e) {
        final idx = e.key;
        final preset = e.value;
        final selected = _selectedPresets.contains(idx);
        return InkWell(
          onTap: () => setState(() {
            if (selected) _selectedPresets.remove(idx);
            else _selectedPresets.add(idx);
          }),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade300),
              borderRadius: BorderRadius.circular(6),
              color: selected
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
                  : null,
            ),
            child: Row(children: [
              Checkbox(value: selected, onChanged: (v) => setState(() {
                if (v == true) _selectedPresets.add(idx);
                else _selectedPresets.remove(idx);
              }), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact),
              const SizedBox(width: 4),
              Icon(preset.icon, size: 18,
                  color: selected ? Theme.of(context).colorScheme.primary : Colors.grey),
              const SizedBox(width: 8),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(preset.app, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Text(preset.reason, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                Text(preset.domains.join(', '),
                    style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.grey)),
              ])),
            ]),
          ),
        );
      }),
      _buildStatus(),
    ]);
  }

  Widget _buildStatus() {
    if (_statusMsg == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Icon(_statusOk ? Icons.check_circle_outline : Icons.error_outline,
            size: 14, color: _statusOk ? Colors.green : Colors.red),
        const SizedBox(width: 6),
        Expanded(child: Text(_statusMsg!,
            style: TextStyle(fontSize: 12,
                color: _statusOk ? Colors.green : Colors.red))),
      ]),
    );
  }

  List<Widget> _buildActions() {
    final isLast = _step == _totalSteps - 1;
    final skipLabel = isLast ? 'Finish' : 'Skip';
    String applyLabel;
    switch (_currentLogical) {
      case 0: applyLabel = 'Install Certificate'; break;
      case 1: applyLabel = 'Enable Loopback'; break;
      case 2: applyLabel = 'Apply Variables'; break;
      case 3: applyLabel = _selectedPresets.isEmpty ? 'Skip' : 'Apply & Finish'; break;
      default: applyLabel = 'Apply';
    }
    return [
      TextButton(
        onPressed: _busy ? null : () async {
          await _nextStep();
        },
        child: Text(skipLabel),
      ),
      if (_currentLogical != 3 || _selectedPresets.isNotEmpty)
        FilledButton(
          onPressed: _busy ? null : _applyAndNext,
          child: _busy
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(applyLabel),
        ),
    ];
  }
}

// Helper classes
class _UwpApp {
  final String name;
  final String packageFamily;
  const _UwpApp({required this.name, required this.packageFamily});
}
