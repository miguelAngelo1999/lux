import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/cert_installer.dart';

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
  const _AppEntry({
    required this.name,
    required this.icon,
    required this.windowsPaths,
    required this.macosPaths,
    required this.domains,
    required this.reason,
  });
}

const _allApps = [
  // Creative / Video
  _AppEntry(
    name: 'DaVinci Resolve',
    icon: Icons.movie_creation,
    windowsPaths: [
      r'C:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe',
      r'C:\Program Files\Blackmagic Design\DaVinci Resolve\DDM\DDM.exe',
    ],
    macosPaths: ['/Applications/DaVinci Resolve/DaVinci Resolve.app'],
    domains: ['*.blackmagicdesign.com', 'resolve-dl.cloud.blackmagicdesign.com'],
    reason: 'DDM download manager uses schannel which requires CRL endpoints',
  ),
  _AppEntry(
    name: 'Adobe Creative Cloud',
    icon: Icons.photo_filter,
    windowsPaths: [
      r'C:\Program Files (x86)\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe',
      r'C:\Program Files\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe',
    ],
    macosPaths: ['/Applications/Adobe Creative Cloud/Adobe Creative Cloud.app'],
    domains: ['*.adobe.com', '*.adobecc.com', 'cc-api-data.adobe.io', '*.services.adobe.com'],
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

  // Developer Tools
  _AppEntry(
    name: 'Visual Studio Code',
    icon: Icons.code,
    windowsPaths: [
      r'C:\Program Files\Microsoft VS Code\Code.exe',
      r'C:\Users\*\AppData\Local\Programs\Microsoft VS Code\Code.exe',
    ],
    macosPaths: ['/Applications/Visual Studio Code.app'],
    domains: ['*.vscode.dev', 'marketplace.visualstudio.com', '*.gallerycdn.vsassets.io',
        'update.code.visualstudio.com', '*.vsassets.io'],
    reason: 'Extension marketplace downloads and updates',
  ),
  _AppEntry(
    name: 'GitHub Desktop',
    icon: Icons.source,
    windowsPaths: [
      r'C:\Users\*\AppData\Local\GitHubDesktop\GitHubDesktop.exe',
    ],
    macosPaths: ['/Applications/GitHub Desktop.app'],
    domains: ['*.github.com', 'api.github.com', 'objects.githubusercontent.com', '*.githubassets.com'],
    reason: 'Repository sync and release downloads',
  ),
  _AppEntry(
    name: 'Docker Desktop',
    icon: Icons.grid_view,
    windowsPaths: [r'C:\Program Files\Docker\Docker\Docker Desktop.exe'],
    macosPaths: ['/Applications/Docker.app'],
    domains: ['*.docker.com', 'registry-1.docker.io', '*.docker.io', 'production.cloudflare.docker.com'],
    reason: 'Image pulls from Docker Hub and registry',
  ),
  _AppEntry(
    name: 'JetBrains IDEs',
    icon: Icons.terminal,
    windowsPaths: [
      r'C:\Program Files\JetBrains\*\bin\*.exe',
      r'C:\Users\*\AppData\Local\JetBrains\Toolbox\apps\*',
    ],
    macosPaths: ['/Applications/JetBrains Toolbox.app', '/Applications/IntelliJ IDEA*.app'],
    domains: ['*.jetbrains.com', 'plugins.jetbrains.com', 'download.jetbrains.com',
        'account.jetbrains.com', '*.intellij.net'],
    reason: 'Plugin downloads and license validation',
  ),
  _AppEntry(
    name: 'Postman',
    icon: Icons.send,
    windowsPaths: [
      r'C:\Users\*\AppData\Local\Postman\Postman.exe',
      r'C:\Program Files\Postman\Postman.exe',
    ],
    macosPaths: ['/Applications/Postman.app'],
    domains: ['*.postman.com', 'api.getpostman.com', 'go.pstmn.io', '*.postmanlabs.com'],
    reason: 'Workspace sync and API collections',
  ),

  // AI Tools
  _AppEntry(
    name: 'Google AI / Gemini Apps',
    icon: Icons.auto_awesome,
    windowsPaths: [],
    macosPaths: [],
    domains: ['generativelanguage.googleapis.com', 'aistudio.google.com',
        '*.googleapis.com', 'optimizationguide-pa.googleapis.com'],
    reason: 'Gemini API calls from Electron and desktop AI apps',
  ),
  _AppEntry(
    name: 'ChatGPT / OpenAI',
    icon: Icons.psychology,
    windowsPaths: [
      r'C:\Users\*\AppData\Local\Programs\chatgpt\ChatGPT.exe',
    ],
    macosPaths: ['/Applications/ChatGPT.app'],
    domains: ['*.openai.com', 'api.openai.com', 'chat.openai.com', '*.oaistatic.com'],
    reason: 'ChatGPT desktop app API calls',
  ),
  _AppEntry(
    name: 'GitHub Copilot (VS Code)',
    icon: Icons.smart_toy,
    windowsPaths: [
      r'C:\Users\*\AppData\Roaming\Code\extensions\github.copilot*',
    ],
    macosPaths: [r'~/.vscode/extensions/github.copilot*'],
    domains: ['copilot-proxy.githubusercontent.com', '*.githubcopilot.com', 'api.github.com'],
    reason: 'Copilot code completion API requests',
  ),

  // Communication & Collaboration
  _AppEntry(
    name: 'Slack',
    icon: Icons.chat_bubble,
    windowsPaths: [
      r'C:\Users\*\AppData\Local\slack\slack.exe',
      r'C:\Program Files\Slack\slack.exe',
    ],
    macosPaths: ['/Applications/Slack.app'],
    domains: ['*.slack.com', 'files.slack.com', '*.slack-edge.com', 'slack.com'],
    reason: 'File uploads/downloads and app integrations',
  ),
  _AppEntry(
    name: 'Microsoft Teams',
    icon: Icons.groups,
    windowsPaths: [
      r'C:\Users\*\AppData\Local\Microsoft\Teams\current\Teams.exe',
      r'C:\Program Files\WindowsApps\MicrosoftTeams*',
    ],
    macosPaths: ['/Applications/Microsoft Teams.app'],
    domains: ['*.teams.microsoft.com', '*.skype.com', 'teams.microsoft.com',
        '*.teams.cdn.office.net'],
    reason: 'Meeting calls and file sharing',
  ),
  _AppEntry(
    name: 'Zoom',
    icon: Icons.video_call,
    windowsPaths: [
      r'C:\Users\*\AppData\Roaming\Zoom\bin\Zoom.exe',
      r'C:\Program Files\Zoom\bin\Zoom.exe',
    ],
    macosPaths: ['/Applications/Zoom.app'],
    domains: ['*.zoom.us', '*.zoomgov.com', 'zoom.us', '*.zmtg.us'],
    reason: 'Meeting connectivity and cloud recordings',
  ),
  _AppEntry(
    name: 'Notion',
    icon: Icons.article,
    windowsPaths: [
      r'C:\Users\*\AppData\Local\Programs\Notion\Notion.exe',
    ],
    macosPaths: ['/Applications/Notion.app'],
    domains: ['*.notion.so', 'api.notion.com', '*.notion-static.com'],
    reason: 'Database sync and file uploads',
  ),
];

// ── App detection ─────────────────────────────────────────────────────────────

Future<List<_AppEntry>> detectInstalledApps() async {
  final found = <_AppEntry>[];
  // Always include AI tools (can't easily detect if a web API is "installed")
  final alwaysShow = ['Google AI / Gemini Apps'];

  for (final app in _allApps) {
    if (alwaysShow.contains(app.name)) {
      found.add(app);
      continue;
    }
    final paths = Platform.isWindows ? app.windowsPaths : app.macosPaths;
    if (paths.isEmpty) continue;
    bool detected = false;
    for (final p in paths) {
      // Handle wildcard paths
      if (p.contains('*')) {
        try {
          final parts = p.split('*');
          final base = parts[0];
          if (await Directory(base).exists()) { detected = true; break; }
        } catch (_) {}
      } else {
        if (await File(p).exists()) { detected = true; break; }
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

  const SetupWizard({super.key, required this.coreManager,
      required this.sslStatus, this.onComplete});

  static Future<void> show(BuildContext context, CoreManager coreManager,
      SslBumpStatus sslStatus) async {
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
      final pem = await widget.coreManager.getSslBumpCert();
      if (pem == null || pem.isEmpty) { _setStatus('No cert available', ok: false); return; }
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
    setState(() => _busy = true); _clearStatus();
    try {
      await widget.coreManager.setMitmEnabled(true);
      for (final idx in _selectedApps) {
        for (final d in _installedApps[idx].domains) {
          try { await widget.coreManager.addMitmPattern(d); } catch (_) {}
        }
      }
      _setStatus('Configured — restart apps for changes to take effect');
    } catch (e) { _setStatus('Failed: $e', ok: false); }
    finally { setState(() => _busy = false); }
  }

  Future<void> _nextStep() async {
    if (_step < _totalSteps - 1) setState(() { _step++; _statusMsg = null; });
    else { Navigator.of(context).pop(); widget.onComplete?.call(); }
  }

  Future<void> _applyAndNext() async {
    switch (_step) {
      case 0: await _doInstallCert(); if (_statusOk) await _nextStep(); break;
      case 1: await _doApplyEnvVars(); if (_statusOk) await _nextStep(); break;
      case 2: await _doApplyMitm(); if (_statusOk) await _nextStep(); break;
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
        Expanded(child: Text(stepTitles[_step], style: const TextStyle(fontSize: 16))),
        Text('${_step+1}/$_totalSteps',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      ]),
      content: SizedBox(width: 440, child: SingleChildScrollView(child: _buildStep())),
      actions: [
        TextButton(onPressed: _busy ? null : _nextStep,
            child: Text(_step == _totalSteps-1 ? 'Finish' : 'Skip')),
        FilledButton(
          onPressed: _busy ? null : _applyAndNext,
          child: _busy
              ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2,color:Colors.white))
              : Text(_step==0 ? 'Install' : _step==1 ? 'Apply' : _selectedApps.isEmpty ? 'Skip' : 'Enable'),
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
      const Text('Your network proxy inspects HTTPS traffic. Install its certificate '
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
          SizedBox(width:6), Text('Certificate installed',style:TextStyle(fontSize:12,color:Colors.green))])],
      _statusWidget(),
    ]);
  }

  Widget _buildEnvStep() {
    if (Platform.isMacOS) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('System configuration is handled automatically on macOS.',
            style: TextStyle(fontSize: 13)),
        const SizedBox(height: 10),
        Container(padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.green.withValues(alpha:0.08),
              border: Border.all(color: Colors.green.shade300), borderRadius: BorderRadius.circular(6)),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children:[Icon(Icons.check_circle,size:14,color:Colors.green),SizedBox(width:6),
              Text('HTTP_PROXY / HTTPS_PROXY set via launchctl', style: TextStyle(fontSize:12))]),
            SizedBox(height:4),
            Row(children:[Icon(Icons.check_circle,size:14,color:Colors.green),SizedBox(width:6),
              Text('CURL_CA_BUNDLE set in /etc/zshenv', style: TextStyle(fontSize:12))]),
            SizedBox(height:4),
            Row(children:[Icon(Icons.check_circle,size:14,color:Colors.green),SizedBox(width:6),
              Text('git & npm proxy configured automatically', style: TextStyle(fontSize:12))]),
          ])),
        const SizedBox(height:8),
        const Text('These are applied automatically when Lux connects.',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        _statusWidget(),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Configure your system so Electron apps, Node.js tools, and '
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
            Expanded(child:Text('UWP app loopback exemption will also be enabled, allowing Windows Store apps to use this connection.',
                style:TextStyle(fontSize:12)))])),
      ],
      _statusWidget(),
    ]);
  }

  Widget _buildMitmStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('The following apps were detected on your computer. Select any that '
          'have trouble connecting — they will be routed through a local proxy '
          'that adds missing certificate information.',
          style: TextStyle(fontSize: 13)),
      const SizedBox(height: 10),
      if (!_appsLoaded)
        const Center(child: Padding(padding: EdgeInsets.all(16),
            child: CircularProgressIndicator()))
      else if (_installedApps.isEmpty)
        const Padding(padding: EdgeInsets.all(12),
          child: Text('No compatible apps detected on this computer.',
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
                  Text(app.name, style: const TextStyle(fontSize:13, fontWeight:FontWeight.w500)),
                  Text(app.reason, style: TextStyle(fontSize:11, color:Colors.grey.shade600)),
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
        Text(title, style: const TextStyle(fontSize:13)),
        Text(subtitle, style: TextStyle(fontSize:11, color:Colors.grey.shade600)),
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
        Expanded(child: Text(_statusMsg!, style: TextStyle(fontSize:12,
            color: _statusOk?Colors.green:Colors.red))),
      ]));
  }
}
