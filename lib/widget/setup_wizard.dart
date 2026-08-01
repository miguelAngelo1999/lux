import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/cert_installer.dart';
import 'package:lux/util/t_text.dart';

// ── App detection & MITM domain registry ─────────────────────────────────────
// Each entry: paths to check for installation + domains the app uses
// Only entries whose app is installed will be shown in the wizard.

class _AppEntry {
  final String name;
  final IconData icon;
  final List<String> windowsPaths; // paths that indicate installation
  final List<String> macosPaths;
  final List<String> domains;
  final String reason; // shown as tooltip/subtitle
  /// If true, this app is known to have TLS cert issues with corporate proxies
  /// (typically Go-based language servers or apps with strict cert validation).
  /// Only apps with hasCertIssues=true are shown in the wizard.
  final bool hasCertIssues;
  const _AppEntry({
    required this.name,
    required this.icon,
    required this.windowsPaths,
    required this.macosPaths,
    required this.domains,
    required this.reason,
    this.hasCertIssues = false,
  });
}

const _allApps = [
  // ── Apps with embedded Go binaries requiring MITM ─────────────────────────
  // These apps contain Go-based language servers or download managers that
  // do strict TLS cert validation (boringcrypto/FIPS). Corporate proxy certs
  // often have non-standard key usage or incomplete chains that Go rejects
  // even when trusted in the system keychain. Lux's MITM CA is properly
  // formed and passes Go strict validation.
  _AppEntry(
    name: 'Antigravity IDE',
    icon: Icons.auto_awesome,
    windowsPaths: [r'C:\Users\*\AppData\Local\Programs\Antigravity IDE\Antigravity IDE.exe'],
    macosPaths: [
      '/Applications/Antigravity IDE.app',
      '/Applications/Antigravity.app',
    ],
    domains: [], // No MITM needed — uses Electron/Node which respects NODE_EXTRA_CA_CERTS
    reason: 'Electron app — NODE_EXTRA_CA_CERTS and NODE_TLS_REJECT_UNAUTHORIZED handle proxy cert trust (set in step 2)',
    hasCertIssues: false, // NOT a Go binary — env vars in System Config step are sufficient
  ),
  _AppEntry(
    name: 'DaVinci Resolve',
    icon: Icons.movie_creation,
    windowsPaths: [
      r'C:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe',
      r'C:\Program Files\Blackmagic Design\DaVinci Resolve\DDM\DDM.exe',
    ],
    macosPaths: [
      '/Applications/DaVinci Resolve',
      '/Applications/DaVinci Resolve/DaVinci Resolve.app',
    ],
    domains: [
      '*.blackmagicdesign.com',
      'resolve-dl.cloud.blackmagicdesign.com',
      'auth.cloud.blackmagicdesign.com',
    ],
    reason: 'DDM download manager is a Go binary — rejects partial corporate proxy cert chains',
    hasCertIssues: true,
  ),
  _AppEntry(
    name: 'Windsurf',
    icon: Icons.air,
    windowsPaths: [r'C:\Users\*\AppData\Local\Programs\Windsurf\Windsurf.exe'],
    macosPaths: ['/Applications/Windsurf.app'],
    domains: [],
    reason: 'Codeium extension — NODE_EXTRA_CA_CERTS handles proxy cert trust',
  ),
  _AppEntry(
    name: 'Kiro',
    icon: Icons.developer_mode,
    windowsPaths: [r'C:\Users\*\AppData\Local\Programs\Kiro\Kiro.exe'],
    macosPaths: [
      '/Applications/Kiro.app',
      '/Applications/Kiro CLI.app',
    ],
    domains: [],
    reason: 'Kiro IDE — NODE_EXTRA_CA_CERTS handles proxy cert trust',
  ),

  // ── Apps that work fine with just NODE_EXTRA_CA_CERTS ─────────────────────
  // These use Node.js/Electron and respect system keychain + NODE_EXTRA_CA_CERTS.
  // Listed here so the wizard can inform users, but no MITM needed.
  _AppEntry(
    name: 'Adobe Creative Cloud',
    icon: Icons.photo_filter,
    windowsPaths: [
      r'C:\Program Files (x86)\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe',
      r'C:\Program Files\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe',
    ],
    macosPaths: ['/Applications/Adobe Creative Cloud/Adobe Creative Cloud.app'],
    domains: ['*.adobe.com', '*.adobecc.com', 'cc-api-data.adobe.io'],
    reason: 'Creative Cloud license checks and update downloads',
  ),
  _AppEntry(
    name: 'Adobe Photoshop',
    icon: Icons.brush,
    windowsPaths: [r'C:\Program Files\Adobe\Adobe Photoshop*'],
    macosPaths: ['/Applications/Adobe Photoshop*'],
    domains: ['*.adobe.com', 'lmlicenses.wip4.adobe.com', '*.adobelogin.com'],
    reason: 'Photoshop license validation and cloud libraries',
  ),
  _AppEntry(
    name: 'Adobe Premiere Pro',
    icon: Icons.video_label,
    windowsPaths: [r'C:\Program Files\Adobe\Adobe Premiere Pro*'],
    macosPaths: ['/Applications/Adobe Premiere Pro*'],
    domains: ['*.adobe.com', '*.adobecc.com', 'ppro.adobe.com'],
    reason: 'Premiere cloud collaboration and media export',
  ),
  _AppEntry(
    name: 'Visual Studio Code',
    icon: Icons.code,
    windowsPaths: [
      r'C:\Program Files\Microsoft VS Code\Code.exe',
      r'C:\Users\*\AppData\Local\Programs\Microsoft VS Code\Code.exe',
    ],
    macosPaths: ['/Applications/Visual Studio Code.app'],
    domains: ['*.vscode.dev', 'marketplace.visualstudio.com', 'update.code.visualstudio.com'],
    reason: 'Extension marketplace downloads and updates',
  ),
  _AppEntry(
    name: 'GitHub Desktop',
    icon: Icons.source,
    windowsPaths: [r'C:\Users\*\AppData\Local\GitHubDesktop\GitHubDesktop.exe'],
    macosPaths: ['/Applications/GitHub Desktop.app'],
    domains: ['*.github.com', 'api.github.com', 'objects.githubusercontent.com'],
    reason: 'Repository sync and release downloads',
  ),
  _AppEntry(
    name: 'Docker Desktop',
    icon: Icons.grid_view,
    windowsPaths: [r'C:\Program Files\Docker\Docker\Docker Desktop.exe'],
    macosPaths: ['/Applications/Docker.app'],
    domains: ['*.docker.com', 'registry-1.docker.io', '*.docker.io'],
    reason: 'Image pulls from Docker Hub and registry',
  ),
  _AppEntry(
    name: 'JetBrains IDEs',
    icon: Icons.terminal,
    windowsPaths: [r'C:\Program Files\JetBrains\*\bin\*.exe'],
    macosPaths: ['/Applications/JetBrains Toolbox.app', '/Applications/IntelliJ IDEA*.app'],
    domains: ['*.jetbrains.com', 'plugins.jetbrains.com', 'download.jetbrains.com'],
    reason: 'Plugin downloads and license validation',
  ),
  _AppEntry(
    name: 'Postman',
    icon: Icons.send,
    windowsPaths: [r'C:\Users\*\AppData\Local\Postman\Postman.exe'],
    macosPaths: ['/Applications/Postman.app'],
    domains: ['*.postman.com', 'api.getpostman.com', 'go.pstmn.io'],
    reason: 'Workspace sync and API collections',
  ),
  _AppEntry(
    name: 'ChatGPT',
    icon: Icons.psychology,
    windowsPaths: [r'C:\Users\*\AppData\Local\Programs\chatgpt\ChatGPT.exe'],
    macosPaths: ['/Applications/ChatGPT.app'],
    domains: ['*.openai.com', 'api.openai.com', 'chat.openai.com'],
    reason: 'ChatGPT desktop app API calls',
  ),
  _AppEntry(
    name: 'Slack',
    icon: Icons.chat_bubble,
    windowsPaths: [r'C:\Users\*\AppData\Local\slack\slack.exe'],
    macosPaths: ['/Applications/Slack.app'],
    domains: ['*.slack.com', 'files.slack.com', '*.slack-edge.com'],
    reason: 'File uploads/downloads and app integrations',
  ),
  _AppEntry(
    name: 'Microsoft Teams',
    icon: Icons.groups,
    windowsPaths: [r'C:\Users\*\AppData\Local\Microsoft\Teams\current\Teams.exe'],
    macosPaths: ['/Applications/Microsoft Teams.app'],
    domains: ['*.teams.microsoft.com', '*.skype.com', 'teams.microsoft.com'],
    reason: 'Meeting calls and file sharing',
  ),
  _AppEntry(
    name: 'Zoom',
    icon: Icons.video_call,
    windowsPaths: [r'C:\Users\*\AppData\Roaming\Zoom\bin\Zoom.exe'],
    macosPaths: ['/Applications/Zoom.app'],
    domains: ['*.zoom.us', 'zoom.us'],
    reason: 'Meeting connectivity and cloud recordings',
  ),
  _AppEntry(
    name: 'Notion',
    icon: Icons.article,
    windowsPaths: [r'C:\Users\*\AppData\Local\Programs\Notion\Notion.exe'],
    macosPaths: ['/Applications/Notion.app'],
    domains: ['*.notion.so', 'api.notion.com'],
    reason: 'Database sync and file uploads',
  ),
];

// ── App detection ─────────────────────────────────────────────────────────────

/// Detects which apps from _allApps are installed.
/// [certIssuesOnly] — if true, only returns apps with hasCertIssues=true
/// (those with Go binaries needing MITM). If false, returns all installed apps.
Future<List<_AppEntry>> detectInstalledApps({bool certIssuesOnly = true}) async {
  final found = <_AppEntry>[];

  for (final app in _allApps) {
    // Filter by cert issues if requested
    if (certIssuesOnly && !app.hasCertIssues) continue;

    final paths = Platform.isWindows ? app.windowsPaths : app.macosPaths;
    if (paths.isEmpty) continue;
    bool detected = false;
    for (final p in paths) {
      // Handle wildcard paths — glob instead of just checking base dir
      if (p.contains('*')) {
        try {
          // Split into the pre-wildcard dir and the remaining suffix
          final starIdx = p.indexOf('*');
          final base = p.substring(0, p.lastIndexOf(Platform.pathSeparator, starIdx) + 1);
          final suffix = p.substring(base.length); // e.g. "*\AppData\Local\Programs\Antigravity IDE\..."

          final baseDir = Directory(base);
          if (!await baseDir.exists()) continue;

          // Get the first path segment of suffix (the wildcard part)
          final suffixParts = suffix.split(RegExp(r'[/\\]'));
          final isWildcardSegment = suffixParts[0] == '*';

          if (isWildcardSegment && suffixParts.length > 1) {
            // e.g. C:\Users\*\AppData\...\App.exe
            // Check each child of base dir for the rest of the path
            final rest = suffix.substring(suffixParts[0].length + 1); // after "*\"
            await for (final child in baseDir.list()) {
              if (child is! Directory) continue;
              final candidate = '${child.path}${Platform.pathSeparator}$rest';
              // The remaining path may also have wildcards (e.g. JetBrains\*\bin\*.exe)
              // For simplicity: check if the next non-wildcard directory segment exists
              final restParts = rest.split(RegExp(r'[/\\]'));
              if (restParts.isEmpty) continue;
              if (restParts.any((seg) => seg == '*')) {
                // Multi-level wildcard: just check the deepest non-wildcard base
                var checkPath = child.path;
                for (final seg in restParts) {
                  if (seg == '*') break;
                  checkPath += '${Platform.pathSeparator}$seg';
                }
                if (await Directory(checkPath).exists() || await File(checkPath).exists()) {
                  detected = true; break;
                }
              } else {
                if (await File(candidate).exists() || await Directory(candidate).exists()) {
                  detected = true; break;
                }
              }
            }
          } else {
            // Simple wildcard — just check base exists (last resort fallback)
            if (await baseDir.exists()) { detected = true; }
          }
        } catch (_) {}
      } else {
        // On macOS, .app bundles are directories — check both File and Directory
        try {
          if (await File(p).exists() || await Directory(p).exists()) {
            detected = true; break;
          }
        } catch (_) {}
      }
    }
    if (detected) found.add(app);
  }
  return found;
}

// ── SetupWizard widget ────────────────────────────────────────────────────────

class SetupWizard extends StatefulWidget {
  final CoreManager coreManager;
  final SslBumpStatus sslStatus;
  final VoidCallback? onComplete;
  /// If set, the wizard opens directly at this step index (0=cert, 1=env, 2=mitm)
  final int? initialStep;

  const SetupWizard({super.key, required this.coreManager,
      required this.sslStatus, this.onComplete, this.initialStep});

  static Future<void> show(BuildContext context, CoreManager coreManager,
      SslBumpStatus sslStatus) async {
    final fp = sslStatus.certInfo?.sha256Fingerprint ?? '';
    // Skip wizard entirely if all steps are dismissed for this cert
    if (fp.isNotEmpty) {
      final allDismissed = await Future.wait([
        isWizardStepDismissed(fp, 'cert'),
        isWizardStepDismissed(fp, 'env'),
        isWizardStepDismissed(fp, 'mitm'),
      ]);
      if (allDismissed.every((d) => d)) return;
    }
    // Machine-specific steps (env, mitm) should only show once per machine,
    // not once per network. Use a stable machine key 'machine' for those.
    // If already dismissed for 'machine', pre-dismiss for this cert too.
    const machineKey = 'machine';
    final envDone  = await isWizardStepDismissed(machineKey, 'env');
    final mitmDone = await isWizardStepDismissed(machineKey, 'mitm');
    if (fp.isNotEmpty) {
      if (envDone)  await dismissWizardStep(fp, 'env');
      if (mitmDone) await dismissWizardStep(fp, 'mitm');
    }
    // Re-check after pre-dismissing machine-specific steps
    if (fp.isNotEmpty) {
      final allDone = await Future.wait([
        isWizardStepDismissed(fp, 'cert'),
        isWizardStepDismissed(fp, 'env'),
        isWizardStepDismissed(fp, 'mitm'),
      ]);
      if (allDone.every((d) => d)) return;
    }
    if (!context.mounted) return;
    // No forced window focus — called from Settings, window is already visible
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
  bool _certInstalled = false;
  bool _dontAskAgain = false; // per-step "don't ask again" checkbox

  // Step: env vars
  bool _setNodeTlsReject = true;
  bool _setNodeExtraCa = true;

  // Step: MITM — detected installed apps
  List<_AppEntry> _installedApps = [];
  final Set<int> _selectedApps = {};
  bool _appsLoaded = false;

  @override
  void initState() {
    super.initState();
    // If opened from a specific settings action, jump to that step
    if (widget.initialStep != null) {
      _step = widget.initialStep!.clamp(0, 2);
    }
    _loadApps();
  }

  Future<void> _loadApps() async {
    final apps = await detectInstalledApps();
    if (mounted) setState(() { _installedApps = apps; _appsLoaded = true; });
  }

  // Steps: 0=ssl, 1=env, 2=mitm (uwp handled inline in env step on Windows)
  int get _totalSteps => 3;

  void _setStatus(String msg, {bool ok = true}) =>
      setState(() { _statusMsg = msg; _statusOk = ok; });
  void _clearStatus() => setState(() => _statusMsg = null);

  Future<void> _doInstallCert() async {
    setState(() => _busy = true); _clearStatus();
    try {
      var pem = await widget.coreManager.getSslBumpCert();
      if (pem == null || pem.isEmpty) {
        // Cert not yet captured — try a fresh probe through lux's local proxy
        // (lux is now connected, so the probe goes through the upstream proxy
        //  and captures the cert)
        _setStatus('Capturing certificate…');
        try {
          final setting = await widget.coreManager.getSetting()
              .catchError((_) => const Setting());
          final port = setting.localServerPort;
          await widget.coreManager.getSslBumpStatus(
            proxyAddr: '127.0.0.1:$port',
            fresh: true,
          );
          // Small delay for lux_core to cache the cert
          await Future.delayed(const Duration(milliseconds: 800));
          pem = await widget.coreManager.getSslBumpCert();
        } catch (_) {}
      }
      if (pem == null || pem.isEmpty) {
        _setStatus('No cert available — connect to the proxy first, then retry', ok: false);
        return;
      }
      final result = await CertInstaller.install(pem);
      if (result.success) { setState(() => _certInstalled = true); _setStatus('Installed successfully'); }
      else _setStatus('Partial — check Settings → SSL Inspection', ok: false);
    } catch (e) { _setStatus('Failed: $e', ok: false); }
    finally { setState(() => _busy = false); }
  }

  Future<void> _doApplyEnvVars() async {
    setState(() => _busy = true); _clearStatus();
    try {
      if (Platform.isWindows) {
        if (_setNodeTlsReject) {
          await Process.run('powershell.exe', ['-noprofile','-NonInteractive','-command',
              '[Environment]::SetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED","0","User")']);
        }
        if (_setNodeExtraCa) {
          final ca = '${Platform.environment['APPDATA']}\\com.github.igoogolx\\lux\\1.0\\mitm_ca.crt';
          if (await File(ca).exists()) {
            await Process.run('powershell.exe', ['-noprofile','-NonInteractive','-command',
                '[Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS","$ca","User")']);
          }
        }
        // Also enable loopback for all UWP apps
        await Process.run('powershell.exe', ['-noprofile','-NonInteractive','-command',
            r'Get-AppxPackage | ForEach-Object { CheckNetIsolation.exe LoopbackExempt -a -n=$($_.PackageFamilyName) 2>$null }']);
      }
      _setStatus('Applied successfully');
    } catch (e) { _setStatus('Failed: $e', ok: false); }
    finally { setState(() => _busy = false); }
  }

  Future<void> _doApplyMitm() async {
    if (_selectedApps.isEmpty) { await _nextStep(); return; }
    setState(() => _busy = true); _clearStatus();    try {
      await widget.coreManager.setMitmEnabled(true);
      for (final idx in _selectedApps) {
        for (final d in _installedApps[idx].domains) {
          try { await widget.coreManager.addMitmPattern(d); } catch (_) {}
        }
      }
      _setStatus('Configured — restart apps for changes to take effect');
    } catch (e) {
      // 500 from setMitmEnabled means the CA could not be initialised —
      // usually a permission issue (key file owned by root from a prior
      // privileged run). The patterns can still be saved; the user just
      // needs to toggle SSL inspection off/on once from Settings to fix it.
      final msg = e.toString();
      if (msg.contains('500') || msg.contains('permission denied') ||
          msg.contains('CA') || msg.contains('initialise')) {
        _setStatus(
          'Saved app list. To activate, go to Settings → Corporate Proxy Fix '
          'and toggle SSL Inspection off then on.',
          ok: true, // treat as soft success
        );
        // Still try to save the patterns even if enable failed
        for (final idx in _selectedApps) {
          for (final d in _installedApps[idx].domains) {
            try { await widget.coreManager.addMitmPattern(d); } catch (_) {}
          }
        }
      } else {
        _setStatus('Failed: $e', ok: false);
      }
    }
    finally { setState(() => _busy = false); }
  }

  Future<void> _nextStep() async {
    // Save "don't ask again" for this step+cert combo AND machine-level
    if (_dontAskAgain) {
      final fp = widget.sslStatus.certInfo?.sha256Fingerprint ?? '';
      final stepName = ['cert', 'env', 'mitm'][_step];
      if (fp.isNotEmpty) await dismissWizardStep(fp, stepName);
      // env/mitm are machine-specific — dismiss globally so new networks skip them
      if (stepName == 'env' || stepName == 'mitm') {
        await dismissWizardStep('machine', stepName);
      }
    }
    if (_step < _totalSteps - 1) {
      var next = _step + 1;
      // Auto-skip dismissed steps
      final fp = widget.sslStatus.certInfo?.sha256Fingerprint ?? '';
      if (fp.isNotEmpty) {
        final stepNames = ['cert', 'env', 'mitm'];
        while (next < _totalSteps && await isWizardStepDismissed(fp, stepNames[next])) {
          next++;
        }
      }
      if (next >= _totalSteps) {
        if (mounted) { Navigator.of(context).pop(); widget.onComplete?.call(); }
      } else {
        setState(() { _step = next; _statusMsg = null; _dontAskAgain = false; });
      }
    } else {
      if (mounted) { Navigator.of(context).pop(); widget.onComplete?.call(); }
    }
  }

  Future<void> _applyAndNext() async {
    switch (_step) {
      case 0: await _doInstallCert(); if (_statusOk) await _nextStep(); break;
      case 1: await _doApplyEnvVars(); if (_statusOk) await _nextStep(); break;
      case 2:
        // _doApplyMitm calls _nextStep() internally when no apps are selected.
        // Guard against double-navigation by checking if dialog is still mounted.
        final wasStep2 = _step;
        await _doApplyMitm();
        // Only call _nextStep if _doApplyMitm didn't already navigate us away
        // (i.e. step didn't change and we're still mounted and _statusOk)
        if (mounted && _step == wasStep2 && _statusOk) await _nextStep();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final stepTitles = ['Install SSL Certificate', 'System Configuration', 'App Compatibility'];
    final stepIcons = [Icons.verified_user, Icons.tune, Icons.security];
    return AlertDialog(
      title: Row(children: [
        Icon(stepIcons[_step], size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: TText(stepTitles[_step], style: const TextStyle(fontSize: 16))),
        Text('${_step+1}/$_totalSteps',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      ]),
      content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStep(),
          // "Don't ask again" lives in content so it doesn't break the action bar layout
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _busy ? null : () => setState(() => _dontAskAgain = !_dontAskAgain),
            child: Row(children: [
              SizedBox(
                width: 20, height: 20,
                child: Checkbox(
                  value: _dontAskAgain,
                  onChanged: _busy ? null : (v) => setState(() => _dontAskAgain = v ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 6),
              TText("Don't ask again for this step",
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ]),
          ),
        ],
      ))),
      actions: [
        TextButton(onPressed: _busy ? null : _nextStep,
            child: TText(_step == _totalSteps-1 ? 'Finish' : 'Skip')),
        FilledButton(
          onPressed: _busy ? null : _applyAndNext,
          child: _busy
              ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white))
              : TText(_step==0 ? 'Install' : _step==1 ? 'Apply' : _selectedApps.isEmpty ? 'Skip' : 'Enable'),
        ),
      ],
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0: return _buildSslStep();
      case 1: return _buildEnvStep();
      case 2: return _buildMitmStep();
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildSslStep() {
    final cert = widget.sslStatus.certInfo;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const TText('Your network proxy inspects HTTPS traffic. Install its certificate '
          'so your browser, git, npm, and curl trust it.',
          style: TextStyle(fontSize: 13)),
      if (cert != null) ...[
        const SizedBox(height: 10),
        Container(padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.orange.withValues(alpha:0.08),
              border: Border.all(color: Colors.orange.shade300), borderRadius: BorderRadius.circular(6)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cert.organizationName.isNotEmpty ? cert.organizationName : cert.subject,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('${cert.sha256Fingerprint.substring(0,29)}…',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.grey)),
          ])),
      ],
      if (_certInstalled) ...[const SizedBox(height:8),
        const Row(children:[Icon(Icons.check_circle,size:14,color:Colors.green),
          SizedBox(width:6), TText('Certificate installed',style:TextStyle(fontSize:12,color:Colors.green))])],
      _statusWidget(),
    ]);
  }

  Widget _buildEnvStep() {
    if (Platform.isMacOS) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TText('System configuration is handled automatically on macOS.',
            style: TextStyle(fontSize: 13)),
        const SizedBox(height: 10),
        Container(padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.green.withValues(alpha:0.08),
              border: Border.all(color: Colors.green.shade300), borderRadius: BorderRadius.circular(6)),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children:[Icon(Icons.check_circle,size:14,color:Colors.green),SizedBox(width:6),
              TText('HTTP_PROXY / HTTPS_PROXY set via launchctl', style: TextStyle(fontSize:12))]),
            SizedBox(height:4),
            Row(children:[Icon(Icons.check_circle,size:14,color:Colors.green),SizedBox(width:6),
              TText('CURL_CA_BUNDLE set in /etc/zshenv', style: TextStyle(fontSize:12))]),
            SizedBox(height:4),
            Row(children:[Icon(Icons.check_circle,size:14,color:Colors.green),SizedBox(width:6),
              TText('git & npm proxy configured automatically', style: TextStyle(fontSize:12))]),
          ])),
        const SizedBox(height:8),
        TText('These are applied automatically when Lux connects.',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        _statusWidget(),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const TText('Configure your system so Electron apps, Node.js tools, and '
          'terminal programs work correctly through the network proxy.',
          style: TextStyle(fontSize: 13)),
      const SizedBox(height: 12),
      _checkRow('Allow Node.js apps to connect (recommended)',
          'Fixes "fetch failed" errors in Electron-based apps like VS Code, Slack, etc.',
          _setNodeTlsReject, (v) => setState(()=>_setNodeTlsReject=v??true)),
      const SizedBox(height: 8),
      _checkRow('Trust proxy CA in Node.js',
          'Adds the proxy certificate to Node.js so npm, yarn, and Electron apps accept it.',
          _setNodeExtraCa, (v) => setState(()=>_setNodeExtraCa=v??true)),
      if (Platform.isWindows) ...[
        const SizedBox(height: 8),
        Container(padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6)),
          child: const Row(children:[Icon(Icons.info_outline,size:14),SizedBox(width:8),
            Expanded(child:TText('UWP app loopback exemption will also be enabled, allowing Windows Store apps to use this connection.',
                style:TextStyle(fontSize:12)))])),
      ],
      _statusWidget(),
    ]);
  }

  Widget _buildMitmStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const TText('The following apps were detected on your computer. Select any that '
          'have trouble connecting — they will be routed through a local proxy '
          'that adds missing certificate information.',
          style: TextStyle(fontSize: 13)),
      const SizedBox(height: 10),
      if (!_appsLoaded)
        const Center(child: Padding(padding: EdgeInsets.all(16),
            child: CircularProgressIndicator()))
      else if (_installedApps.isEmpty)
        const Padding(padding: EdgeInsets.all(12),
          child: TText('No compatible apps detected on this computer.',
              style: TextStyle(color: Colors.grey)))
      else
        ..._installedApps.asMap().entries.map((e) {
          final idx = e.key; final app = e.value;
          final sel = _selectedApps.contains(idx);
          return GestureDetector(
            onTap: () => setState(()=>sel?_selectedApps.remove(idx):_selectedApps.add(idx)),
            child: Container(margin: const EdgeInsets.only(bottom:6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  border: Border.all(color: sel
                      ? Theme.of(context).colorScheme.primary : Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                  color: sel ? Theme.of(context).colorScheme.primary.withValues(alpha:0.07) : null),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Checkbox(value: sel, onChanged: (v)=>setState(()=>v==true?_selectedApps.add(idx):_selectedApps.remove(idx)),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
                const SizedBox(width:6),
                Icon(app.icon, size:18, color: sel?Theme.of(context).colorScheme.primary:Colors.grey),
                const SizedBox(width:8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
                  TText(app.name, style: const TextStyle(fontSize:13, fontWeight:FontWeight.w500)),
                  TText(app.reason, style: TextStyle(fontSize:11, color:Colors.grey.shade600)),
                ])),
              ])),
          );
        }),
      _statusWidget(),
    ]);
  }

  Widget _checkRow(String title, String subtitle, bool value, ValueChanged<bool?> onChanged) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Checkbox(value: value, onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
      const SizedBox(width:4),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TText(title, style: const TextStyle(fontSize:13)),
        TText(subtitle, style: TextStyle(fontSize:11, color:Colors.grey.shade600)),
      ])),
    ]);
  }

  Widget _statusWidget() {
    if (_statusMsg == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top:8),
      child: Row(children:[
        Icon(_statusOk?Icons.check_circle_outline:Icons.error_outline, size:14,
            color: _statusOk?Colors.green:Colors.red),
        const SizedBox(width:6),
        Expanded(child: TText(_statusMsg!, style: TextStyle(fontSize:12,
            color: _statusOk?Colors.green:Colors.red))),
      ]));
  }
}
