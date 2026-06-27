import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:lux/const/const.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/util/cert_installer.dart';
import 'package:lux/util/installed_certs_store.dart';
import 'package:lux/util/network_detector.dart';
import 'package:lux/util/network_reset.dart';
import 'package:lux/dashboard.dart';
import 'package:lux/model/app.dart';
import 'package:lux/tr.dart';
import 'package:lux/tray.dart';
import 'package:lux/util/notifier.dart';
import 'package:flutter/services.dart';
import 'package:lux/util/process_manager.dart';
import 'package:lux/widget/quick_edit_window.dart';
import 'package:lux/util/utils.dart';
import 'package:lux/widget/progress_indicator.dart';
import 'package:path/path.dart' as path;
import 'package:power_monitor/power_monitor.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:version/version.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

import 'core/core_config.dart';

class Home extends StatefulWidget {
  final ClientMode clientMode;

  const Home(this.clientMode, {super.key});

  @override
  State<Home> createState() => _HomeState();
}

Future<void> initClient(CoreManager? coreManager) async {
  await setAutoConnect(coreManager);
  await setAutoLaunch(coreManager);
}

class _HomeState extends State<Home>
    with TrayListener, WindowListener, PowerMonitorListener {
  String baseUrl = "";
  String urlStr = "";
  String homeDir = "";
  CoreManager? coreManager;
  NetworkDetector? _networkDetector;
  ValueNotifier<bool> isCoreReady = ValueNotifier<bool>(false);
  Widget? dashboardWidget;
  WebSocketChannel? eventChannel;
  late final AppLifecycleListener _listener;
  var needRestart = false;
  dynamic coreError;
  bool _quickEditMode = false;
  String? _lastDetectedCertFingerprint;
  VoidCallback? _proxyListRefresh; // set by Dashboard, called after adding a proxy
  final _quickEditChannel = const MethodChannel('lux_quick_edit');

  Future<void> _handleNativeQuickEdit(MethodCall call) async {
    if (call.method == 'onSave' && coreManager != null) {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final proxyId = args['proxyId'] as String;
      final username = args['username'] as String;
      final password = args['password'] as String;
      final passwordMode = args['passwordMode'] as String? ?? 'persistent';
      final ttlMinutes = args['ttlMinutes'] as int? ?? 60;
      try {
        final detail = await coreManager!.getProxyDetail(proxyId);
        if (detail == null) return;
        final updated = Map<String, dynamic>.from(detail.raw);
        updated['username'] = username;
        updated['password'] = password;
        updated['passwordMode'] = passwordMode;
        if (passwordMode == 'timed') {
          updated['passwordTTLMinutes'] = ttlMinutes;
        }
        await coreManager!.updateProxy(proxyId, updated);
        _refreshTray();
      } catch (e) {
        debugPrint('Quick edit save error: $e');
      }
    }
  }

  // ΓöÇΓöÇ Network proxy auto-detection ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

  final Set<String> _dismissedProxies = {};

  Future<void> _loadDismissedProxies() async {
    final saved = await readDismissedProxies();
    _dismissedProxies.addAll(saved);
  }

  /// Early detection ΓÇö reads system proxy via scutil BEFORE lux_core starts.
  /// Early detection — reads system proxy via scutil (macOS) or registry (Windows)
  /// BEFORE lux_core starts. Called at app init so the system proxy hasn't been
  /// overwritten by Lux yet.
  Future<void> _detectProxyEarly() async {
    if (!mounted) return;
    try {
      if (Platform.isWindows) {
        // On Windows, lux_core's /proxies/detect handles registry + winhttp detection.
        // Nothing to do here before lux_core starts — defer to _checkForNetworkProxy().
        return;
      }
      // macOS: use scutil
      final result = await Process.run('scutil', ['--proxy'],
          runInShell: false).timeout(const Duration(seconds: 3));
      final out = result.stdout as String;
      final lines = out.split('\n');
      final settings = <String, String>{};
      for (final line in lines) {
        final parts = line.trim().split(' : ');
        if (parts.length == 2) {
          settings[parts[0].trim()] = parts[1].trim();
        }
      }

      // Check explicit HTTP/HTTPS proxy
      for (final prefix in ['HTTP', 'HTTPS']) {
        if (settings['${prefix}Enable'] == '1') {
          final host = settings['${prefix}Proxy'] ?? '';
          final port = settings['${prefix}Port'] ?? '8080';
          if (host.isEmpty || host == '127.0.0.1' || host == 'localhost') continue;
          if (_dismissedProxies.contains('$host:$port')) continue;
          final detected = DetectedProxy(
            host: host,
            port: port,
            scheme: prefix.toLowerCase(),
            needsAuth: false,
            source: 'scutil',
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showProxyAndCertDialog(
              detected,
              SslBumpStatus(detected: false, hasCert: false, error: 'not_probed'),
            );
          });
          return;
        }
      }

      // Check PAC/WPAD auto-config proxy
      if (settings['ProxyAutoConfigEnable'] == '1') {
        final pacUrl = settings['ProxyAutoConfigURLString'] ?? '';
        if (pacUrl.isNotEmpty) {
          // Parse proxy from PAC URL host or defer to lux_core detection later
          // For now, show a generic detection prompt
          final uri = Uri.tryParse(pacUrl);
          final host = uri?.host ?? '';
          if (host.isNotEmpty && host != '127.0.0.1' && host != 'localhost') {
            if (_dismissedProxies.contains(host)) return;
            final detected = DetectedProxy(
              host: host,
              port: uri?.port.toString() ?? '8080',
              scheme: 'http',
              needsAuth: false,
              source: 'wpad',
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showProxyAndCertDialog(
                detected,
                SslBumpStatus(detected: false, hasCert: false, error: 'not_probed'),
              );
            });
            return;
          }
        }
      }

      // Check ProxyAutoDiscoveryEnable (WPAD via DHCP)
      if (settings['ProxyAutoDiscoveryEnable'] == '1') {
        // WPAD is enabled — defer to lux_core's DHCP/DNS WPAD probe after startup
        debugPrint('WPAD auto-discovery enabled — deferring to lux_core detection');
      }
    } catch (_) {}
    // Fall back to lux_core detection after it starts
  }

  // -- Proxy address detected at startup --
  String? _detectedProxyAddr;

  /// On Windows with a corporate proxy, ensure DNS is set to dhcp://auto
  /// so TUN/Mixed mode works without DNS failures (corporate proxies block 8.8.8.8).
  Future<void> _ensureCorporateDns() async {
    if (coreManager == null) return;
    try {
      final rawRes = await coreManager!.dio.get(
          'http://${coreManager!.baseUrl}/setting');
      final raw = Map<String, dynamic>.from(rawRes.data['setting'] as Map);
      final dns = Map<String, dynamic>.from(raw['dns'] as Map? ?? {});
      final server = Map<String, dynamic>.from(dns['server'] as Map? ?? {});
      final remote = List<String>.from(server['remote'] as List? ?? []);
      // If remote DNS has only external servers (8.8.8.8, 1.1.1.1 etc), add dhcp://auto
      final hasLocal = remote.any((s) => s.contains('dhcp') || s.contains('system'));
      if (!hasLocal) {
        server['remote'] = ['dhcp://auto', ...remote];
        dns['server'] = server;
        raw['dns'] = dns;
        await coreManager!.dio.put(
            'http://${coreManager!.baseUrl}/setting', data: raw);
        debugPrint('[DNS] Auto-added dhcp://auto for corporate network');
      }
    } catch (e) {
      debugPrint('[DNS] Failed to update DNS: $e');
    }
  }

  Future<void> _checkForNetworkProxy() async {
    if (coreManager == null || !mounted) return;
    if (!mounted) return;
    try {
      final detected = await coreManager!.detectNetworkProxy();

      // Always do a direct SSL probe — transparent proxy gives cert without auth
      final sslStatus = await coreManager!.getSslBumpStatus(fresh: true);

      if (detected == null || !mounted) {
        // Detection failed but SSL bump detected — show dialog with empty fields
        if (sslStatus.detected && sslStatus.hasCert && mounted) {
          // Create a synthetic DetectedProxy — host empty, user fills it in
          // The cert org name will be pre-filled as proxy name by the dialog
          final syntheticProxy = DetectedProxy(
            host: '',
            port: '8080',
            scheme: 'http',
            source: 'ssl-bump',
            needsAuth: true,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showProxyAndCertDialog(syntheticProxy, sslStatus);
          });
        }
        return;
      }

      _detectedProxyAddr = detected.address;

      SslBumpStatus finalSsl;
      if (detected.needsAuth && !Platform.isWindows) {
        // macOS: Give auto-connect time to complete (it starts immediately with backoff)
        await Future.delayed(const Duration(seconds: 3));
        bool isConnected = false;
        try { isConnected = await coreManager!.getIsStarted(); } catch (_) {}
        if (isConnected) {
          final setting = await coreManager!.getSetting().catchError((_) => const Setting());
          final localPort = setting.localServerPort;
          finalSsl = await coreManager!.getSslBumpStatus(
            proxyAddr: '127.0.0.1:$localPort',
            fresh: true,
          );
        } else {
          finalSsl = sslStatus; // use the direct probe result
        }
      } else {
        finalSsl = sslStatus; // use already-fetched direct probe
      }

      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showProxyAndCertDialog(detected, finalSsl);
      });
    } catch (e) {
      debugPrint('Proxy detection error: $e');
    }
  }

  /// Single combined dialog: proxy info + SSL status + add fields.
  Future<void> _showProxyAndCertDialog(
      DetectedProxy detected, SslBumpStatus ssl) async {
    if (_dismissedProxies.contains(detected.address)) return;

    // Use the SSL cert's organization name as default proxy name if available
    final defaultName = ssl.certInfo?.organizationName.isNotEmpty == true
        ? ssl.certInfo!.organizationName
        : detected.host;

    final nameCtrl   = TextEditingController(text: defaultName);
    final serverCtrl = TextEditingController(text: detected.host);
    final portCtrl   = TextEditingController(text: detected.port);
    final userCtrl   = TextEditingController();
    final passCtrl   = TextEditingController();
    final userFocus  = FocusNode();
    final passFocus  = FocusNode();
    bool obscure = true;
    bool dontShowAgain = false;
    bool autoSelect = true; // auto-select new proxy as active after adding
    BuildContext? _dialogCtx; // set when dialog opens, used by Enter key

    // Extracted add logic — called by both the button and Enter on password field
    Future<void> _doAdd() async {
      if (_dialogCtx != null) Navigator.of(_dialogCtx!).pop();
      final server = serverCtrl.text.trim();
      final port   = portCtrl.text.trim();
      final user   = userCtrl.text;
      final pass   = passCtrl.text;
      final name   = nameCtrl.text.trim().isNotEmpty
          ? nameCtrl.text.trim()
          : 'Network Proxy ($server)';
      try {
        await coreManager!.addProxy({
          'type': 'http', 'name': name, 'server': server,
          'port': int.tryParse(port) ?? 8080,
          if (user.isNotEmpty) 'username': user,
          if (pass.isNotEmpty) 'password': pass,
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Proxy added — checking SSL…')));
        String proxyAddr;
        if (user.isNotEmpty) {
          proxyAddr = '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@$server:$port';
        } else {
          proxyAddr = '$server:$port';
        }
        final freshSsl = await coreManager!.getSslBumpStatus(proxyAddr: proxyAddr, fresh: true);
        if (!mounted) return;
        if (freshSsl.detected && freshSsl.hasCert) {
          final fp = freshSsl.certInfo?.sha256Fingerprint ?? '';
          final certOrg = freshSsl.certInfo?.organizationName ?? '';
          // Always rename to cert org name if we got one and it differs from current name
          if (certOrg.isNotEmpty && name != certOrg) {
            try {
              final proxyList = await coreManager!.getProxyList();
              final added = proxyList.proxies.lastWhere(
                  (p) => p.server == server, orElse: () => proxyList.proxies.last);
              await coreManager!.updateProxy(added.id, {
                'name': certOrg, 'server': server,
                'port': int.tryParse(port) ?? 8080,
                if (user.isNotEmpty) 'username': user,
                if (pass.isNotEmpty) 'password': pass,
              });
            } catch (_) {}
          }
          if (await InstalledCertsStore.isFullyInstalled(fp)) return;
          _lastDetectedCertFingerprint = fp;
          _showInlineCertTrustDialog(freshSsl);
        } else if (freshSsl.error != null && freshSsl.error!.contains('407')) {          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Proxy still requires auth — check credentials and try again from Settings → SSL Inspection'),
            duration: Duration(seconds: 5)));
        } else if (freshSsl.detected && !freshSsl.hasCert) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('SSL interception detected — connect to proxy to capture certificate'),
            duration: Duration(seconds: 4)));
        }
        // Refresh the proxies page so the new proxy appears immediately
        _proxyListRefresh?.call();
        // Auto-select the new proxy as active if checkbox is checked
        if (autoSelect) {
          try {
            final proxyList = await coreManager!.getProxyList();
            final added = proxyList.proxies.lastWhere(
                (p) => p.server == server, orElse: () => proxyList.proxies.last);
            await coreManager!.selectProxy(added.id);
            _proxyListRefresh?.call();
          } catch (_) {}
        }
        // On Windows in TUN/Mixed mode, auto-configure DNS to use DHCP/system
        // so corporate networks don't block DNS (they block 8.8.8.8 but not their own DNS)
        if (Platform.isWindows) {
          try {
            await _ensureCorporateDns();
          } catch (_) {}
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed: $e')));
      }
    }

    final sourceLabel = const {
      'dhcp_wpad':      'DHCP/WPAD',
      'wpad_dns':       'WPAD DNS',
      'dhcp_option252': 'DHCP',
      'pac':            'PAC',
      'scutil':         'System',
    };

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          _dialogCtx = ctx;
          return KeyboardListener(
            focusNode: FocusNode()..requestFocus(),
            onKeyEvent: (event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter) {
                _doAdd();
              }
            },
            child: AlertDialog(
          title: const Row(children: [
            Icon(Icons.wifi_find, size: 20),
            SizedBox(width: 8),
            Text('Network Proxy Detected', style: TextStyle(fontSize: 16)),
          ]),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Proxy address + source badge
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(children: [
                      const Icon(Icons.dns, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(detected.address,
                            style: const TextStyle(fontSize: 14,
                                fontWeight: FontWeight.w500)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          sourceLabel[detected.source] ?? detected.source,
                          style: TextStyle(fontSize: 10,
                              color: Theme.of(ctx)
                                  .colorScheme.onSecondaryContainer),
                        ),
                      ),
                    ]),
                  ),

                  // SSL bump result
                  const SizedBox(height: 10),
                  if (ssl.detected) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade800.withValues(alpha: 0.12),
                        border: Border.all(color: Colors.orange.shade600),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(children: [
                            Icon(Icons.security, size: 14, color: Colors.orange),
                            SizedBox(width: 6),
                            Text('SSL Interception Detected',
                                style: TextStyle(fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.orange)),
                          ]),
                          if (ssl.certInfo != null) ...[
                            const SizedBox(height: 8),
                            _buildCertSummary(ssl.certInfo!),
                          ],
                          const SizedBox(height: 6),
                          const Text(
                            'This proxy decrypts HTTPS. '
                            'You can install its CA cert after adding it.',
                            style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ] else if (ssl.error != null && (ssl.error!.contains('407') || detected.needsAuth)) ...[
                    // Auth required — can't probe SSL without credentials
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade800.withValues(alpha: 0.10),
                        border: Border.all(color: Colors.blue.shade600),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(children: [
                            Icon(Icons.info_outline, size: 13, color: Colors.blue),
                            SizedBox(width: 4),
                            Text('SSL check requires credentials',
                                style: TextStyle(fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.blue)),
                          ]),
                          const SizedBox(height: 4),
                          const Text(
                            'Enter your username & password below, then add the proxy. '
                            'SSL inspection will be checked in Settings after connecting.',
                            style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ] else if (ssl.error == null && !detected.needsAuth) ...[
                    // Only show "no SSL interception" if we actually probed successfully
                    Row(children: const [
                      Icon(Icons.shield_outlined, size: 13, color: Colors.green),
                      SizedBox(width: 4),
                      Text('No SSL interception detected',
                          style: TextStyle(fontSize: 12, color: Colors.green)),
                    ]),
                  ],

                  // Fields
                  const SizedBox(height: 14),
                  const Divider(),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Name', isDense: true,
                        border: OutlineInputBorder()),
                    style: const TextStyle(fontSize: 13),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: serverCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Server', isDense: true,
                            border: OutlineInputBorder()),
                        style: const TextStyle(fontSize: 13),
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: portCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Port', isDense: true,
                            border: OutlineInputBorder()),
                        style: const TextStyle(fontSize: 13),
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) =>
                            FocusScope.of(ctx).requestFocus(userFocus),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  TextField(
                    controller: userCtrl,
                    focusNode: userFocus,
                    decoration: const InputDecoration(
                        labelText: 'Username (optional)', isDense: true,
                        border: OutlineInputBorder()),
                    style: const TextStyle(fontSize: 13),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) =>
                        FocusScope.of(ctx).requestFocus(passFocus),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passCtrl,
                    focusNode: passFocus,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'Password (optional)',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined, size: 16),
                        onPressed: () => setSt(() => obscure = !obscure),
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _doAdd(),
                  ),
                  if (detected.needsAuth) ...[
                    const SizedBox(height: 4),
                    const Row(children: [
                      Icon(Icons.lock_outline, size: 12, color: Colors.orange),
                      SizedBox(width: 4),
                      Text('407 auth required',
                          style: TextStyle(fontSize: 11, color: Colors.orange)),
                    ]),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            // Checkboxes on left, buttons on right
            Row(
              children: [
                Checkbox(
                  value: dontShowAgain,
                  onChanged: (v) => setSt(() => dontShowAgain = v ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                GestureDetector(
                  onTap: () => setSt(() => dontShowAgain = !dontShowAgain),
                  child: const Text('Don\'t show again',
                      style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 12),
                Checkbox(
                  value: autoSelect,
                  onChanged: (v) => setSt(() => autoSelect = v ?? true),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                GestureDetector(
                  onTap: () => setSt(() => autoSelect = !autoSelect),
                  child: const Text('Auto-select',
                      style: TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    _dismissedProxies.add(detected.address);
                    if (dontShowAgain) {
                      addDismissedProxy(detected.address);
                    }
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Ignore'),
                ),
                FilledButton(
                  onPressed: _doAdd,
                  child: Text(ssl.detected && ssl.hasCert
                      ? 'Add & Install Certificate'
                      : 'Add to Lux'),
                ),
              ],
            ),
          ],
          ), // closes AlertDialog
          ); // closes KeyboardListener
        }, // closes StatefulBuilder builder
      ), // closes StatefulBuilder
    ); // closes showDialog

    nameCtrl.dispose(); serverCtrl.dispose(); portCtrl.dispose();
    userCtrl.dispose(); passCtrl.dispose();
    userFocus.dispose(); passFocus.dispose();
  }


  /// Shows the SSL cert trust dialog inline (same as Settings page but triggered automatically).
  void _showInlineCertTrustDialog(SslBumpStatus status) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.security, color: Colors.orange, size: 22),
            SizedBox(width: 8),
            Flexible(child: Text('Proxy intercepts HTTPS', style: TextStyle(fontSize: 16))),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your network proxy is intercepting HTTPS traffic (SSL inspection). '
                'To browse securely through this proxy, you need to trust its certificate.',
                style: TextStyle(fontSize: 13),
              ),
              if (status.certInfo != null) ...[
                const SizedBox(height: 12),
                _buildCertSummary(status.certInfo!),
              ],
              const SizedBox(height: 12),
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
                        'Only trust this if you control this proxy or your IT department configured it.',
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
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Skip for now'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _installCertInline();
            },
            child: const Text('Trust & Install Certificate'),
          ),
        ],
      ),
    );
  }

  Widget _buildCertSummary(CertInfo info) {
    final name = info.organizationName.isNotEmpty ? info.organizationName : info.subject;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade700),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name.isNotEmpty)
            Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          Text('Valid: ${info.notBefore} / ${info.notAfter}',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  Future<void> _installCertInline() async {
    if (coreManager == null || !mounted) return;
    try {
      final pemBytes = await coreManager!.getSslBumpCert();
      if (pemBytes == null || pemBytes.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No certificate available')));
        return;
      }
      final result = await CertInstaller.install(pemBytes);
      if (result.success && _lastDetectedCertFingerprint != null) {
        final successStores = result.steps
            .where((s) => s.success)
            .map((s) => s.name)
            .toList();
        await InstalledCertsStore.markInstalled(
            _lastDetectedCertFingerprint!, successStores);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.success
              ? 'Certificate installed successfully'
              : 'Partial install — check Settings \u2192 SSL Inspection for details'),
          backgroundColor: result.success ? Colors.green.shade700 : Colors.orange.shade700,
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Install failed: $e')));
    }
  }

  /// Shows the Flutter QuickEditWindow near the system tray (bottom-right).
  /// Used by the Windows tray "Edit Credentials" menu.
  Future<void> _showFlutterQuickEdit(String proxyId) async {
    const size = Size(340, 390);
    await windowManager.setSize(size);
    try {
      final pos = await calcWindowPosition(size, Alignment.bottomRight);
      await windowManager.setPosition(Offset(pos.dx - 12, pos.dy - 8));
    } catch (_) {
      // If screen retriever fails, just center it
      await windowManager.center();
    }
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    if (mounted) {
      setState(() => _quickEditMode = true);
    }
  }

  // Reload proxy list and connection state into tray menu
  Future<void> _refreshTray() async {    if (coreManager == null) return;
    try {
      final isStarted = await coreManager!.getIsStarted();
      final proxyList = await coreManager!.getProxyList();
      initSystemTray(
        isConnected: isStarted,
        proxies: proxyList.proxies,
        selectedProxyId: proxyList.id,
      );
    } catch (_) {
      initSystemTray();
    }
  }

  void _init(AppStateModel appState) async {
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);
    // Load persisted dismissed proxies before detection runs
    await _loadDismissedProxies();

    // Detect network proxy early — before lux_core starts, so system proxy
    // settings still reflect the real upstream proxy (not Lux's own 127.0.0.1)
    _detectProxyEarly();

    var corePath = path.join(Paths.assetsBin.path, LuxCoreName.name);
    var curHomeDir = await getHomeDir();
    final port = await findAvailablePort(8000, 9000);
    var uuid = Uuid();
    var secret = uuid.v4();
    final Version currentVersion = Version.parse(await getAppVersion());
    var needElevate = true;
    var homeDirArg = '-home_dir=$curHomeDir';
    if (Platform.isWindows) {
      homeDirArg = "-home_dir=`\"$curHomeDir`\"";
      final proxyMode = await readProxyMode();
      needElevate = proxyMode != ProxyMode.system;
    }
    final process = ProcessManager(
        corePath, [homeDirArg, '-port=$port', '-secret=$secret'], needElevate);
    var curBaseUrl = '127.0.0.1:$port';
    var curHttpUrl = 'http://$curBaseUrl';
    var curUrlStr =
        '$curHttpUrl/?client_version=$currentVersion&token=$secret&theme=${appState.theme == ThemeMode.dark ? 'dark' : 'light'}';
    debugPrint("dashboard url: $curUrlStr");
    coreManager = CoreManager(curBaseUrl, process, secret, () {
      _onCoreReady(appState);
    });
    _networkDetector = NetworkDetector(coreManager!);

    setState(() {
      homeDir = curHomeDir;
      baseUrl = curHttpUrl;
      urlStr = curUrlStr;
    });

    if (Platform.isWindows || Platform.isMacOS) {
      initSystemTray();
      _refreshTray();
    }

    isCoreReady.addListener(() {
      if (isCoreReady.value) {
        initClient(coreManager);
        _refreshTray();
      }
    });
    coreManager?.run().catchError((e) {
      setState(() {
        coreError = e;
      });
    });

    // Watchdog: if lux_core dies unexpectedly, reset network settings
    // so internet isn't permanently broken by stale system proxy / TUN.
    _startCoreWatchdog();
  }

  void _startCoreWatchdog() {
    final proc = coreManager?.coreProcess?.process;
    if (proc == null) return;
    // Watch for unexpected exit
    proc.exitCode.then((code) async {
      debugPrint('[watchdog] lux_core exited with code $code');
      if (mounted && code != 0) {
        await NetworkReset.reset();
        debugPrint('[watchdog] network reset after unexpected core exit');
      }
    });
    // Heartbeat: ping lux_core every 15s. If it stops responding, reset network.
    _startHeartbeat();
  }

  void _startHeartbeat() {
    if (coreManager == null) return;
    int _failCount = 0;
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 15));
      if (!mounted || coreManager == null) return false;
      try {
        await coreManager!.getIsStarted().timeout(const Duration(seconds: 10));
        _failCount = 0; // reset on success
        return mounted;
      } catch (e) {
        _failCount++;
        debugPrint('[watchdog] lux_core unresponsive (attempt $_failCount): $e');
        // Auto-recover: reset network + restart core silently
        await NetworkReset.reset();
        try {
          await coreManager!.restart();
          debugPrint('[watchdog] lux_core restarted successfully');
          _failCount = 0;
          return mounted; // continue watchdog
        } catch (restartErr) {
          debugPrint('[watchdog] restart failed: $restartErr');
          if (_failCount >= 3) {
            // Only show error after 3 consecutive failures
            if (mounted) {
              setState(() {
                coreError = Exception('lux_core failed to restart — please restart Lux manually.');
              });
            }
            return false;
          }
          return mounted; // keep trying
        }
      }
    });
  }

  void _onCoreReady(AppStateModel appState) {
    setState(() {
      isCoreReady.value = true;
    });
    // After core starts, probe for a network proxy in the background
    // and ensure SSL bump certs are installed if needed.
    Future.delayed(const Duration(milliseconds: 500), () => _checkForNetworkProxy());
    // Detect corporate vs home network and switch rules accordingly
    Future.delayed(const Duration(seconds: 3), () { _networkDetector?.detect(); });
    if (eventChannel == null) {
      coreManager?.getEventChannel().then((channel) async {
        if (channel == null) return;
        await channel.ready;
        eventChannel = channel;
        eventChannel?.stream.listen((rawData) async {
          if (rawData is! String) {
            return;
          }
          final message = json.decode(rawData);
          if (message is! Map<String, dynamic>) {
            return;
          }
          if (!(message.containsKey('type') && message['type'] is String)) {
            return;
          }

          switch (message['type']) {
            case "set_theme":
              {
                if (!(message.containsKey('value') &&
                    message['value'] is String)) {
                  return;
                }
                appState.updateTheme(convertTheme(message['value']));
              }
            case "set_language":
              {
                if (!(message.containsKey('value') &&
                    message['value'] is String)) {
                  return;
                }
                appState.updateLocale(convertLocale(message['value']));
                if (Platform.isWindows) {
                  initSystemTray();
                }
              }
            case "set_auto_launch":
              {
                if (!(message.containsKey('value') &&
                    message['value'] is bool)) {
                  return;
                }
                if (message['value']) {
                  await launchAtStartup.enable();
                } else {
                  await launchAtStartup.disable();
                }
              }
            case 'open_home_dir':
              {
                launchUrl(Uri.file(homeDir));
              }
            case 'open_web_dashboard':
              {
                launchUrl(Uri.parse(urlStr));
              }
            case 'exit_app':
              {
                await coreManager?.exitCore();
                exitApp();
              }
          }
        });
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onExitRequested: _handleExitRequest);
    windowManager.addListener(this);
    powerMonitor.addListener(this);
    // Listen for save callbacks from native quick edit panel
    _quickEditChannel.setMethodCallHandler(_handleNativeQuickEdit);
    _init(Provider.of<AppStateModel>(context, listen: false));
  }

  Future<AppExitResponse> _handleExitRequest() async {
    if (Platform.isMacOS) {
      await coreManager?.safeExit();
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    powerMonitor.removeListener(this);
    _listener.dispose();
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.setSkipTaskbar(false);
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    final key = menuItem.key ?? '';

    if (key == 'open_dashboard') {
      if (_quickEditMode) {
        setState(() => _quickEditMode = false);
        await windowManager.setSize(const Size(800, 650));
        await windowManager.center();
      }
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    } else if (key == 'connect') {
      await coreManager?.start();
      _refreshTray();
    } else if (key == 'disconnect') {
      await coreManager?.stop();
      _refreshTray();
    } else if (key.startsWith('proxy_select_')) {
      // Switch to selected proxy
      final proxyId = key.replaceFirst('proxy_select_', '');
      await coreManager?.selectProxy(proxyId);
      _refreshTray();
    } else if (key.startsWith('proxy_edit_')) {
      // Show native Swift floating panel near menubar
      if (Platform.isMacOS && coreManager != null) {
        try {
          final proxyList = await coreManager!.getProxyList();
          // Build a simple list with credentials for the native panel
          final proxiesWithCreds = <Map<String, dynamic>>[];
          for (final p in proxyList.proxies) {
            if (p.type == 'direct') continue;
            final detail = await coreManager!.getProxyDetail(p.id);
            proxiesWithCreds.add({
              'id': p.id,
              'name': p.name,
              'username': detail?.raw['username'] ?? '',
              'password': detail?.password ?? '',
              'passwordMode': detail?.raw['passwordMode'] ?? 'persistent',
              'ttlMinutes': detail?.raw['passwordTTLMinutes'] ?? 60,
            });
          }
          await _quickEditChannel.invokeMethod('showNearMenubar', {
            'proxies': proxiesWithCreds,
            'selectedId': proxyList.id,
          });
        } catch (e) {
          debugPrint('Native quick edit error: $e');
        }
      } else if (Platform.isWindows && coreManager != null) {
        final proxyId = key.replaceFirst('proxy_edit_', '');
        _showFlutterQuickEdit(proxyId);
      }
    } else if (key == 'exit_app') {
      await coreManager?.exitCore();
      exit(0);
    }
  }

  @override
  onPowerMonitorSleep() async {
    if (Platform.isMacOS) {
      var isFullScreen = await windowManager.isFullScreen();
      if (isFullScreen) {
        await windowManager.setFullScreen(false);
      }
    }
    if (coreManager == null) {
      return;
    }
    var isStarted = await coreManager!.getIsStarted();
    if (!isStarted) {
      return;
    }
    final setting = await coreManager!.getSetting();
    if (setting.mode == ProxyMode.tun || setting.mode == ProxyMode.mixed) {
      needRestart = true;
      await coreManager!.stop();
    }
  }

  @override
  onPowerMonitorWokeUp() async {
    if (coreManager == null) {
      return;
    }
    // Re-detect network after wake (may have switched networks during sleep)
    Future.delayed(const Duration(seconds: 3), () { _networkDetector?.detect(); });
    if (needRestart) {
      needRestart = false;
      final List<ConnectivityResult> connectivityResult =
          await (Connectivity().checkConnectivity());
      if (connectivityResult.contains(ConnectivityResult.none)) {
        notifier.show(tr().noConnectionMsg);
        return;
      }
      await Future.delayed(const Duration(seconds: 2));

      await coreManager!.start();
      notifier.show(tr().reconnectedMsg);
    }
  }

  @override
  onPowerMonitorShutdown() {
    resetSystemProxy();
  }

  @override
  onPowerMonitorUserChanged() async {
    if (coreManager == null) {
      return;
    }
    var isStarted = await coreManager!.getIsStarted();
    if (isStarted) {
      await coreManager!.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (coreError != null && !isCoreReady.value) {
      throw coreError;
    }
    if (coreManager == null || !isCoreReady.value) {
      return Scaffold(body: AppProgressIndicator());
    }
    if (_quickEditMode) {
      return QuickEditWindow(
        coreManager: coreManager!,
        onDone: () async {
          setState(() => _quickEditMode = false);
          // Restore full window size and hide back to tray
          await windowManager.setSize(const Size(800, 650));
          await windowManager.center();
          await windowManager.hide();
          await windowManager.setSkipTaskbar(true);
          _refreshTray();
        },
      );
    }
    return Dashboard(homeDir, baseUrl, urlStr, coreManager!,
        onConnected: () {},
        onRegisterProxyRefresh: (cb) => _proxyListRefresh = cb);
  }
}
