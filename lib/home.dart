import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:lux/const/const.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/util/app_log.dart';
import 'package:lux/util/cert_installer.dart';
import 'package:lux/util/installed_certs_store.dart';
import 'package:lux/util/network_detector.dart';
import 'package:lux/util/network_reset.dart';
import 'package:lux/widget/setup_wizard.dart';
import 'package:lux/dashboard.dart';
import 'package:lux/model/app.dart';
import 'package:lux/tr.dart';
import 'package:lux/tray.dart';
import 'package:lux/util/notifier.dart';
import 'package:flutter/services.dart';
import 'package:lux/util/core_lockfile.dart';
import 'package:lux/util/process_manager.dart';
import 'package:lux/widget/quick_edit_window.dart';
import 'package:lux/util/utils.dart' hide checkForUpdate;
import 'package:lux/util/updater.dart' show checkForUpdate, showUpdateDialog;
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
import 'package:lux/util/t_text.dart';
import 'package:lux/widget/proxy_edit_dialog.dart';

class Home extends StatefulWidget {
  final ClientMode clientMode;
  final bool silentStart;

  const Home(this.clientMode, {super.key, this.silentStart = false});

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
  final _dockChannel = const MethodChannel('lux_dock');

  /// Hide the window and remove the dock icon (tray-only mode).
  Future<void> _hideWindow() async {
    await windowManager.hide().catchError((_) {});
    if (Platform.isMacOS) {
      _dockChannel.invokeMethod('hide').catchError((_) {});
    }
  }

  /// Show the window and restore the dock icon.
  Future<void> _showWindow() async {
    if (Platform.isMacOS) {
      await _dockChannel.invokeMethod('show').catchError((_) {});
    }
    await windowManager.show();
    await windowManager.focus();
  }
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

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

  /// Silently applies UWP loopback exemption for all installed Windows Store apps.
  /// This allows apps like Teams, Slack, etc. to route through lux as system proxy.
  /// Also sets NODE_TLS_REJECT_UNAUTHORIZED and NODE_EXTRA_CA_CERTS if not already set.
  /// Runs once in the background — no dialog, no user interaction needed.
  Future<void> _ensureUwpLoopback() async {
    try {
      // UWP loopback exemption — use a single batched PowerShell call
      // instead of spawning CheckNetIsolation.exe hundreds of times.
      // Limit to 60s timeout to avoid hanging indefinitely.
      appLog('UWP', 'applying loopback exemption...');
      final result = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-WindowStyle', 'Hidden', '-command',
        r'$pkgs = Get-AppxPackage | Select-Object -ExpandProperty PackageFamilyName; '
        r'foreach ($pkg in $pkgs) { CheckNetIsolation.exe LoopbackExempt -a "-n=$pkg" 2>$null }',
      ]).timeout(const Duration(seconds: 60));
      appLog('UWP', 'loopback exemption done exit=${result.exitCode}');

      // NODE_TLS_REJECT_UNAUTHORIZED — only set if not already present
      final existing = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        '[Environment]::GetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED","User")',
      ]);
      if (existing.stdout.toString().trim().isEmpty) {
        await Process.run('powershell.exe', [
          '-noprofile', '-NonInteractive', '-command',
          '[Environment]::SetEnvironmentVariable("NODE_TLS_REJECT_UNAUTHORIZED","0","User")',
        ]);
        debugPrint('[UWP] set NODE_TLS_REJECT_UNAUTHORIZED=0');
      }

      // NODE_EXTRA_CA_CERTS — only set if CA file exists and var not already present
      final caPath = '${Platform.environment['APPDATA']}\\com.github.igoogolx\\lux\\1.0\\mitm_ca.crt';
      final caExists = await File(caPath).exists();
      if (caExists) {
        final existingCa = await Process.run('powershell.exe', [
          '-noprofile', '-NonInteractive', '-command',
          '[Environment]::GetEnvironmentVariable("NODE_EXTRA_CA_CERTS","User")',
        ]);
        if (existingCa.stdout.toString().trim().isEmpty) {
          await Process.run('powershell.exe', [
            '-noprofile', '-NonInteractive', '-command',
            '[Environment]::SetEnvironmentVariable("NODE_EXTRA_CA_CERTS","$caPath","User")',
          ]);
          debugPrint('[UWP] set NODE_EXTRA_CA_CERTS=$caPath');
        }
      }
    } catch (e) {
      appLog('UWP', 'background setup failed: $e');
      debugPrint('[UWP] background setup failed: $e');
    }
  }

  /// On Windows with a corporate proxy, ensure DNS is set to use the local
  /// DHCP DNS server directly (UDP) so TUN/Mixed mode works without DNS failures.
  /// Corporate proxies block tcp://8.8.8.8:53 but local DNS is always reachable.
  Future<void> _ensureCorporateDns() async {
    if (coreManager == null) return;
    try {
      final rawRes = await coreManager!.dio.get(
          'http://${coreManager!.baseUrl}/setting');
      final raw = Map<String, dynamic>.from(rawRes.data['setting'] as Map);
      final dns = Map<String, dynamic>.from(raw['dns'] as Map? ?? {});
      final server = Map<String, dynamic>.from(dns['server'] as Map? ?? {});
      final remote = List<String>.from(server['remote'] as List? ?? []);

      // Check if we already have a local DNS (bare IP = UDP, or dhcp/system)
      final hasLocal = remote.any((s) =>
          s.contains('dhcp') || s.contains('system') ||
          RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(s));

      if (!hasLocal) {
        // Get actual DHCP DNS IPs — bare IP = UDP, works through TUN
        final dhcpDns = await _getDhcpDnsServers();
        if (dhcpDns.isNotEmpty) {
          server['remote'] = [...dhcpDns, ...remote];
          dns['server'] = server;
          raw['dns'] = dns;
          await coreManager!.dio.put(
              'http://${coreManager!.baseUrl}/setting', data: raw);
          debugPrint('[DNS] Auto-added DHCP DNS $dhcpDns for corporate network');
        }
      }
    } catch (e) {
      debugPrint('[DNS] Failed to update DNS: $e');
    }
  }

  /// Get DHCP DNS server IPs on Windows via PowerShell (bare IPs = UDP).
  /// Only returns servers that actually respond to DNS queries.
  Future<List<String>> _getDhcpDnsServers() async {
    if (!Platform.isWindows) return [];
    try {
      // Get candidate DNS servers from DHCP
      final result = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-command',
        r'(Get-DnsClientServerAddress -AddressFamily IPv4 | '
        r'Where-Object { $_.ServerAddresses -and '
        r'($_.ServerAddresses | Where-Object { $_ -notmatch "^(127\.|198\.18\.)" }) } | '
        r'Select-Object -First 1).ServerAddresses | '
        r'Where-Object { $_ -notmatch "^(127\.|198\.18\.)" } | '
        r'Select-Object -First 2 | Join-String -Separator ","',
      ]);
      final out = result.stdout.toString().trim();
      if (out.isEmpty) return [];
      final candidates = out.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

      // Verify each server actually responds to DNS before using it
      final reachable = <String>[];
      for (final ip in candidates) {
        try {
          final testResult = await Process.run('powershell.exe', [
            '-noprofile', '-NonInteractive', '-command',
            'try { '
            '  \$r = Resolve-DnsName "dns.msftncsi.com" -Server "$ip" -Type A '
            '    -ErrorAction Stop -NoHostsFile; '
            '  Write-Output "ok" '
            '} catch { Write-Output "fail" }',
          ]).timeout(const Duration(seconds: 5));
          if (testResult.stdout.toString().trim() == 'ok') {
            reachable.add(ip);
            debugPrint('[DNS] Verified DNS server: $ip');
          } else {
            debugPrint('[DNS] DNS server unreachable: $ip');
          }
        } catch (_) {
          debugPrint('[DNS] DNS server test timed out: $ip');
        }
      }
      return reachable;
    } catch (_) {
      return [];
    }
  }

  /// DEBUG ONLY: simulate an SSL bump detection to test the cert install flow
  /// without needing a real corporate network.
  /// - [alreadyInstalled]: if true, simulates cert already in all stores (should NOT prompt)
  /// - [alreadyInstalled] false: simulates new cert (SHOULD show dialog)
  Future<void> _debugSimulateSslBump({bool alreadyInstalled = false}) async {
    if (!kDebugMode) return;
    if (coreManager == null || !mounted) return;

    // Fake cert info — realistic-looking corporate proxy CA
    const fakeFp = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';
    const fakeFpClean = 'AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899';

    if (alreadyInstalled) {
      await InstalledCertsStore.markInstalled(fakeFpClean, ['macOS System Keychain', 'curl', 'Node.js']);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: TText('🔬 Debug: cert marked as installed — triggering network-change path'),
        duration: Duration(seconds: 2),
      ));
      // Mimic the connectivity listener's check — should silently skip
      if (await InstalledCertsStore.isFullyInstalled(fakeFpClean)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: TText('✅ Correctly skipped — cert already fully installed'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ));
        return;
      }
    }

    // Simulate a fresh detection — should show the proxy+cert dialog
    final fakeDetected = DetectedProxy(
      host: '10.0.0.1',
      port: '8080',
      scheme: 'http',
      source: 'debug-simulation',
      needsAuth: true,
    );
    final fakeSsl = SslBumpStatus(
      detected: true,
      hasCert: true,
      certInfo: const CertInfo(
        organizationName: 'Debug Corp Proxy CA',
        sha256Fingerprint: fakeFpClean,
        subject: 'CN=debug-proxy.corp.example, O=Debug Corp',
        issuer: 'CN=Debug Corp Root CA',
        notBefore: '2026-01-01T00:00:00Z',
        notAfter: '2027-01-01T00:00:00Z',
        isCA: true,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showProxyAndCertDialog(fakeDetected, fakeSsl);
    });
  }

  // Debounce for _checkForNetworkProxy — don't re-run within 60s of last run
  DateTime? _lastProxyCheck;
  bool _reconnectInProgress = false;
  DateTime? _lastReconnectAttempt;

  /// Run NetworkDetector.detect() only when lux_core has been stable for
  /// at least 10 seconds. Prevents false bypass_all switches during startup
  /// when TUN interface is still coming up and the proxy probe times out.
  /// Returns true if on corporate network, false if bypassed/unknown.
  Future<bool> _safeDetect() async {
    if (_networkDetector == null || !mounted) return false;
    if (!isCoreReady.value) {
      appLog('NET-DETECT', 'skipping detect — lux_core not ready yet');
      return false;
    }
    // Wait for TUN to stabilize after startup
    final lastStart = coreManager?.lastStartTime;
    if (lastStart != null &&
        DateTime.now().difference(lastStart).inSeconds < 10) {
      appLog('NET-DETECT', 'skipping detect — lux_core started <10s ago (TUN stabilizing)');
      return false;
    }
    return await _networkDetector!.detect();
  }
  // Guard against running check while wizard is already showing
  bool _wizardShowing = false;
  // Guard against showing the proxy dialog twice simultaneously
  bool _proxyDialogShowing = false;

  Future<void> _checkForNetworkProxy({bool force = false}) async {
    // Don't re-run within 60 seconds (prevents connectivity-change retriggering)
    // force=true bypasses debounce for explicit startup/retry calls
    final now = DateTime.now();
    if (!force && _lastProxyCheck != null && now.difference(_lastProxyCheck!).inSeconds < 60) return;
    _lastProxyCheck = now;
    // Don't stack wizards
    if (_wizardShowing) return;

    if (coreManager == null || !mounted) return;
    appLog('NET', 'checkForNetworkProxy started');
    try {
      final detected = await coreManager!.detectNetworkProxy();
      // Always do a direct SSL probe — transparent proxy gives cert without auth
      final sslStatus = await coreManager!.getSslBumpStatus(fresh: true);

      // ── Determine what still needs to be done ─────────────────────────────

      // Check if this proxy is already in Lux's proxy list
      bool proxyAlreadyAdded = false;
      if (detected != null && detected.host.isNotEmpty) {
        try {
          final proxyList = await coreManager!.getProxyList();
          proxyAlreadyAdded = proxyList.proxies.any(
              (p) => p.server == detected.host && p.port.toString() == detected.port);
        } catch (_) {}
      }

      // Check if the cert is already installed in all stores
      final certFp = sslStatus.certInfo?.sha256Fingerprint ?? '';
      final certAlreadyInstalled = certFp.isNotEmpty
          ? await InstalledCertsStore.isFullyInstalled(certFp)
          : false;

      final hasBump = sslStatus.detected && sslStatus.hasCert;

      // ── Decision tree ─────────────────────────────────────────────────────
      // Case 1: No proxy detected, no SSL bump → nothing to do
      if (detected == null && !hasBump) return;

      // Case 2: Proxy known + cert installed → nothing left to do
      if (proxyAlreadyAdded && certAlreadyInstalled) return;

      // Case 3: Proxy known + cert NOT installed → show a non-intrusive snackbar
      // instead of forcing the wizard popup. User can install from Settings → SSL & MITM.
      if (proxyAlreadyAdded && hasBump && !certAlreadyInstalled) {
        appLog('NET', 'cert not installed — notifying via snackbar');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: TText('Proxy CA certificate available to install'),
            action: SnackBarAction(
              label: 'Install',
              onPressed: () {
                // Navigate to SSL & MITM settings
                // Just show a brief hint — user opens settings manually
              },
            ),
            duration: const Duration(seconds: 6),
          ));
        }
        return;
      }

      // Case 4: Proxy not yet added (new network or new proxy) → full dialog
      // Also handles: no proxy detected but SSL bump found (transparent proxy)
      SslBumpStatus finalSsl;
      if (detected != null && detected.needsAuth && !Platform.isWindows) {
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
          finalSsl = sslStatus;
        }
      } else {
        finalSsl = sslStatus;
      }

      if (!mounted) return;

      if (detected == null) {
        // SSL bump detected but no proxy found.
        // Don't show the empty-server dialog — the retry call will get the real address.
        // Only show if this is a forced/retry call (meaning we've already waited for core to be ready).
        if (!hasBump) return;
        if (!force) return; // Wait for the retry to get the actual server address
        final syntheticProxy = DetectedProxy(
          host: '', port: '8080', scheme: 'http',
          source: 'ssl-bump', needsAuth: true,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_proxyDialogShowing) _showProxyAndCertDialog(syntheticProxy, finalSsl);
        });
      } else {
        _detectedProxyAddr = detected.address;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_proxyDialogShowing) _showProxyAndCertDialog(detected, finalSsl);
        });
      }
    } catch (e) {
      appLog('NET', 'checkForNetworkProxy error: $e');
      debugPrint('Proxy detection error: $e');
    }
  }

  /// Single combined dialog: proxy info + SSL status + add fields.
  Future<void> _showProxyAndCertDialog(
      DetectedProxy detected, SslBumpStatus ssl) async {
    if (detected.host.isNotEmpty && _dismissedProxies.contains(detected.address)) return;
    if (_proxyDialogShowing) return; // already showing — don't stack dialogs
    _proxyDialogShowing = true;

    // Bring app to foreground to ensure user sees the prompt
    await _showWindow();

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
    final keyboardFocus = FocusNode(); // persistent — not recreated on rebuild
    bool obscure = true;
    bool dontShowAgain = false;
    bool autoSelect = true; // auto-select new proxy as active after adding
    bool scanning = false;  // true while re-scanning for proxy address
    BuildContext? _dialogCtx; // set when dialog opens, used by Enter key

    // Re-scan for proxy address — called by the Scan button in the dialog
    Future<void> _doScan(StateSetter setSt) async {
      if (coreManager == null) return;
      setSt(() => scanning = true);
      try {
        final found = await coreManager!.detectNetworkProxy();
        if (found != null && found.host.isNotEmpty) {
          setSt(() {
            serverCtrl.text = found.host;
            portCtrl.text   = found.port;
            if (nameCtrl.text.isEmpty || nameCtrl.text == detected.host) {
              nameCtrl.text = found.host;
            }
          });
          appLog('NET', 'manual scan found ${found.address} via ${found.source}');
        } else {
          // Nothing found — give a brief visual feedback
          appLog('NET', 'manual scan: no proxy detected');
        }
      } catch (e) {
        appLog('NET', 'manual scan error: $e');
      } finally {
        setSt(() => scanning = false);
      }
    }

    bool _adding = false; // guard against double-add (button + Enter simultaneously)

    // Extracted add logic — called by both the button and Enter on password field
    Future<void> _doAdd() async {
      if (_adding) return; // prevent double-add
      _adding = true;
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
        // Skip SSL re-probe if it was already detected in the dialog
        final SslBumpStatus freshSsl;
        if (ssl.detected && ssl.hasCert) {
          freshSsl = ssl; // reuse already-detected SSL info — no need to re-probe
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: TText('Proxy added — checking SSL…')));
          String proxyAddr;
          if (user.isNotEmpty) {
            proxyAddr = '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@$server:$port';
          } else {
            proxyAddr = '$server:$port';
          }
          freshSsl = await coreManager!.getSslBumpStatus(proxyAddr: proxyAddr, fresh: true);
        }
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
          // Notify via snackbar instead of forcing wizard popup
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: TText('Proxy CA certificate ready to install — see Settings → SSL & MITM'),
              duration: const Duration(seconds: 6),
            ));
          }
        } else if (freshSsl.error != null && freshSsl.error!.contains('407')) {          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: TText('Proxy still requires auth — check credentials and try again from Settings → SSL Inspection'),
            duration: Duration(seconds: 5)));
        } else if (freshSsl.detected && !freshSsl.hasCert) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: TText('SSL interception detected — connect to proxy to capture certificate'),
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
            // Auto-connect if not already running
            final isStarted = await coreManager!.getIsStarted().catchError((_) => false);
            if (!isStarted) {
              await coreManager!.start().catchError((_) {});
            }
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
          // Request focus once so Enter key works immediately (not on every rebuild)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!keyboardFocus.hasFocus) keyboardFocus.requestFocus();
          });
          return KeyboardListener(
            focusNode: keyboardFocus,
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
            TText('Network Proxy Detected', style: TextStyle(fontSize: 16)),
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
                        child: Text(
                          detected.host.isEmpty
                              ? 'Corporate proxy detected — enter address below'
                              : detected.address,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: detected.host.isEmpty ? Colors.orange : null,
                          ),
                        ),
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
                            TText('SSL Interception Detected',
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
                            TText('SSL check requires credentials',
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
                      TText('No SSL interception detected',
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
                    const SizedBox(width: 4),
                    // Scan button — re-runs proxy detection and fills server/port
                    Tooltip(
                      message: tl(context, 'Scan for proxy'),
                      child: SizedBox(
                        width: 36, height: 36,
                        child: scanning
                            ? const Padding(
                                padding: EdgeInsets.all(8),
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.search, size: 18),
                                onPressed: () => _doScan(setSt),
                              ),
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
                      TText('407 auth required',
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
                  child: TText('Auto-select',
                      style: TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    if (detected.host.isNotEmpty) {
                      _dismissedProxies.add(detected.address);
                      if (dontShowAgain) {
                        addDismissedProxy(detected.address);
                      }
                    }
                    Navigator.of(ctx).pop();
                  },
                  child: TText('Ignore'),
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
    userFocus.dispose(); passFocus.dispose(); keyboardFocus.dispose();
    _proxyDialogShowing = false; // allow new dialogs after this one closes
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
            Flexible(child: TText('Proxy intercepts HTTPS', style: TextStyle(fontSize: 16))),
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
            child: TText('Skip for now'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _installCertInline();
            },
            child: TText('Trust & Install Certificate'),
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
          const SnackBar(content: TText('No certificate available')));
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
    await _showWindow();
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
    // setPreventClose is a UI-only concern — don't await it here as it can
    // hang on macOS when the app launches in the background (window manager
    // not ready until app is foregrounded). Fire and forget.
    windowManager.setPreventClose(true).catchError((_) {});
    // Load persisted dismissed proxies before detection runs
    await _loadDismissedProxies();
    // Migrate any old store names in the cert store (e.g. 'Node.js' → 'Node.js / npm')
    // so isFullyInstalled() doesn't keep returning false for already-installed certs.
    await InstalledCertsStore.ensureConsistentStoreNames();

    // Detect network proxy early — before lux_core starts, so system proxy
    // settings still reflect the real upstream proxy (not Lux's own 127.0.0.1)
    _detectProxyEarly();

    var corePath = path.join(Paths.assetsBin.path, LuxCoreName.name);
    var curHomeDir = await getHomeDir();
    await initAppLog(curHomeDir);
    appLog('APP', 'init started homeDir=$curHomeDir');
    final Version currentVersion = Version.parse(await getAppVersion());

    // ── LaunchAgent fast path (macOS only) ──────────────────────────────────
    // If the LaunchAgent pre-started lux_core, a lockfile exists with the
    // fixed port and persistent secret. Try to connect to it directly —
    // no new process launch needed, no scheduler throttle problem.
    int port;
    String secret;
    ProcessManager? process;

    if (Platform.isMacOS) {
      final lock = await readLockfile(curHomeDir);
      if (lock != null) {
        // Verify lux_core is actually responding on that port
        bool alive = false;
        try {
          final testSocket = await Socket.connect('127.0.0.1', lock.port,
              timeout: const Duration(seconds: 2));
          testSocket.destroy();
          alive = true;
        } catch (_) {}

        if (alive) {
          appLog('CORE', 'LaunchAgent lux_core already running on port=${lock.port} — skipping launch');
          port = lock.port;
          secret = lock.secret;
          process = null; // no process to manage — LaunchAgent owns it
        } else {
          appLog('CORE', 'lockfile found but lux_core not responding — will relaunch');
          await deleteLockfile(curHomeDir);
          port = luxCoreFixedPort;
          secret = const Uuid().v4();
          await writeLockfile(curHomeDir, CoreLockfile(port: port, secret: secret));
          process = ProcessManager(
              corePath,
              ['-home_dir=$curHomeDir', '-port=$port', '-secret=$secret'],
              true);
        }
      } else {
        // No lockfile — LaunchAgent not installed yet or first launch.
        // Use fixed port so lockfile written here is valid for future LaunchAgent starts.
        port = luxCoreFixedPort;
        secret = const Uuid().v4();
        await writeLockfile(curHomeDir, CoreLockfile(port: port, secret: secret));
        process = ProcessManager(
            corePath,
            ['-home_dir=$curHomeDir', '-port=$port', '-secret=$secret'],
            true);
      }
    } else {
      // Windows — keep existing dynamic port behavior
      port = await findAvailablePort(8000, 9000);
      secret = const Uuid().v4();
      var needElevate = true;
      var homeDirArg = "-home_dir=`\"$curHomeDir`\"";
      final proxyMode = await readProxyMode();
      needElevate = proxyMode != ProxyMode.system;
      process = ProcessManager(
          corePath, [homeDirArg, '-port=$port', '-secret=$secret'], needElevate);
    }
    // ────────────────────────────────────────────────────────────────────────

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
      appLog('CORE', 'lux_core failed to start: $e');
      setState(() {
        coreError = e;
      });
      // Show window on error so user sees what went wrong
      _showWindow();
    });

    // Hide the window after run() is called (or after we confirmed core is
    // already running). On macOS the window was already briefly shown then
    // hidden in waitUntilReadyToShow to force Flutter engine initialization.
    // On Windows we hide here if it's a silent start.
    if (widget.silentStart && Platform.isWindows) {
      windowManager.hide().catchError((_) {});
    }

    // Watchdog: if lux_core dies unexpectedly, reset network settings
    // so internet isn't permanently broken by stale system proxy / TUN.
    _startCoreWatchdog();
  }

  /// Called when connectivity is restored. If autoConnect is enabled and lux
  /// is not running, silently start it so internet is restored automatically.
  Future<void> _reconnectIfNeeded() async {
    if (!mounted || coreManager == null) return;
    // Debounce: ignore if a reconnect ran within the last 10 seconds
    final now = DateTime.now();
    if (_lastReconnectAttempt != null &&
        now.difference(_lastReconnectAttempt!).inSeconds < 10) return;
    // Guard: only one reconnect loop at a time
    if (_reconnectInProgress) return;
    _reconnectInProgress = true;
    _lastReconnectAttempt = now;
    try {
      await _doReconnectIfNeeded();
    } finally {
      _reconnectInProgress = false;
    }
  }

  Future<void> _doReconnectIfNeeded() async {
    if (!mounted || coreManager == null) return;
    try {
      final isStarted = await coreManager!.getIsStarted().timeout(
          const Duration(seconds: 5));
      if (isStarted) return;
      final setting = await coreManager!.getSetting().catchError((_) => const Setting());
      if (!setting.autoConnect) return;
      appLog('WATCHDOG', 'connectivity restored + autoConnect on + not started — reconnecting');

      // Try start() up to 3 times with backoff — handles transient 500s.
      // After each failure, re-check isStarted: lux_core may have auto-started
      // itself during the WiFi handover, in which case 500 "already started" is
      // NOT a real failure — treat it as success.
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          await coreManager!.start();
          appLog('WATCHDOG', 'reconnected after connectivity restore (attempt $attempt)');
          return;
        } catch (e) {
          appLog('WATCHDOG', 'reconnect attempt $attempt failed: $e');
          // Check if lux_core started itself during this attempt (race condition
          // on WiFi switch: core auto-starts, our /start call gets 500 "already started")
          try {
            final alreadyUp = await coreManager!.getIsStarted().timeout(
                const Duration(seconds: 5));
            if (alreadyUp) {
              // lux_core is running but connections may be stale from before
              // the outage. Force a stop+start to get fresh connections.
              appLog('WATCHDOG', 'lux_core running after attempt $attempt — forcing stop+start to clear stale connections');
              try {
                await coreManager!.stop();
                await Future.delayed(const Duration(seconds: 2));
                await coreManager!.start();
                appLog('WATCHDOG', 'reconnected after forced stop+start');
                return;
              } catch (restartE) {
                appLog('WATCHDOG', 'stop+start failed: $restartE — continuing retries');
              }
            }
          } catch (_) {}
          if (attempt < 3) await Future.delayed(Duration(seconds: attempt * 5));
        }
      }

      // 3 failures — try lux_core process restart (kills and respawns lux_core_real)
      appLog('WATCHDOG', 'start() failed 3x — restarting lux_core process');
      try {
        await coreManager!.restart();
        await Future.delayed(const Duration(seconds: 3));
        await coreManager!.start();
        appLog('WATCHDOG', 'reconnected after lux_core restart');
        return;
      } catch (e) {
        appLog('WATCHDOG', 'lux_core restart also failed: $e');
      }

      // lux_core is in an unrecoverable state — full Lux.app relaunch
      appLog('WATCHDOG', 'lux_core unrecoverable — relaunching Lux.app');
      await _relaunchApp();
    } catch (e) {
      appLog('WATCHDOG', 'reconnect check failed: $e');
    }
  }

  /// Writes a tiny detached shell script that waits for this process to exit,
  /// then relaunches Lux.app. Mirrors the updater pattern.
  /// After writing the script, exits Lux — the script outlives us.
  Future<void> _relaunchApp() async {
    if (Platform.isWindows) {
      // On Windows: reset network then relaunch via a detached PowerShell process
      try {
        appLog('WATCHDOG', 'relaunching on Windows');
        await NetworkReset.reset();
        final exePath = Platform.resolvedExecutable;
        await Process.start(
          'powershell.exe',
          ['-noprofile', '-NonInteractive', '-command',
           'Start-Sleep -Seconds 2; Start-Process "$exePath"'],
          mode: ProcessStartMode.detached,
        );
        await Future.delayed(const Duration(milliseconds: 500));
        exit(0);
      } catch (e) {
        appLog('WATCHDOG', 'Windows relaunch failed: $e');
      }
      return;
    }
    if (!Platform.isMacOS) return;
    try {
      appLog('WATCHDOG', 'writing relaunch script and exiting');
      await NetworkReset.reset();
      // Write relaunch script to lux home dir (not /tmp — more reliable, persisted)
      final scriptPath = '$homeDir/lux_relaunch.sh';
      final script = File(scriptPath);
      await script.writeAsString(
        '#!/bin/bash\n'
        'exec >> /tmp/lux_relaunch.log 2>&1\n'
        'echo "relaunch script started at \$(date)"\n'
        '\n'
        '# Wait for Lux.app to fully exit (it calls exit(0) right after launching us)\n'
        'for i in \$(seq 1 15); do\n'
        '  if ! pgrep -x Lux > /dev/null 2>&1; then\n'
        '    echo "Lux exited after \$i seconds"\n'
        '    break\n'
        '  fi\n'
        '  sleep 1\n'
        'done\n'
        '\n'
        '# Now kill lux_core_real (Lux is gone so no one will restart it)\n'
        'sudo pkill -9 -x lux_core_real 2>/dev/null || true\n'
        'sleep 1\n'
        '\n'
        '# Relaunch as the logged-in user (not as root)\n'
        'LOGGED_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "\$USER")\n'
        'echo "relaunching Lux.app as \$LOGGED_USER"\n'
        'sudo -u "\$LOGGED_USER" open /Applications/Lux.app\n'
        'echo "relaunch done at \$(date)"\n',
      );
      await Process.run('chmod', ['+x', scriptPath]);
      // Start detached — Process.start without await so it runs independently
      await Process.start('bash', [scriptPath],
          mode: ProcessStartMode.detached);
      await Future.delayed(const Duration(milliseconds: 500));
      exit(0);
    } catch (e) {
      appLog('WATCHDOG', 'relaunch script failed: $e');
    }
  }

  void _startCoreWatchdog() {
    final proc = coreManager?.coreProcess?.process;
    if (proc == null) return;
    appLog('WATCHDOG', 'started — monitoring lux_core process');
    // Watch for unexpected exit
    proc.exitCode.then((code) async {
      appLog('WATCHDOG', 'lux_core exited with code=$code — unexpected=${code != 0}');
      debugPrint('[watchdog] lux_core exited with code $code');
      if (mounted && code != 0) {
        await NetworkReset.reset();
        appLog('WATCHDOG', 'network reset after unexpected core exit code=$code');
      }
    });
    _startHeartbeat();
  }

  /// Simple heartbeat: every 30s call GET /health on lux_core.
  /// /health probes generate_204 through lux's own proxy tunnel end-to-end.
  /// Escalation: soft reconnect → lux_core restart → full Lux.app relaunch.
  void _startHeartbeat() {
    if (coreManager == null) return;
    int failCount = 0;
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 30));
      if (!mounted || coreManager == null) return false;
      try {
        final health = await coreManager!.getHealth();
        if (health.ok) {
          if (failCount > 0) appLog('WATCHDOG', 'health restored (latency: ${health.latency}ms)');
          failCount = 0;
          return mounted;
        }
        failCount++;
        appLog('WATCHDOG', 'health FAILED ($failCount): ${health.error}');
        if (failCount == 2) {
          // Two consecutive failures — first try network detection (may be home network)
          appLog('WATCHDOG', 'triggering network detection after $failCount health failures');
          if (_networkDetector != null) {
            final isCorpNetwork = await _safeDetect();
            if (!isCorpNetwork) {
              // Switched to bypass — don't stop+start, NetworkDetector handles it
              appLog('WATCHDOG', 'switched to bypass mode — skipping stop+start');
              failCount = 0;
              return mounted;
            }
          }
          // Still on corp network — soft reconnect (stop+start)
          appLog('WATCHDOG', 'soft reconnect after $failCount health failures');
          try {
            await coreManager!.stop();
            await Future.delayed(const Duration(seconds: 2));
            await coreManager!.start();
            appLog('WATCHDOG', 'soft reconnect succeeded');
            failCount = 0;
          } catch (e) {
            appLog('WATCHDOG', 'soft reconnect failed: $e');
          }
        } else if (failCount == 4) {
          // Four failures — restart lux_core process
          appLog('WATCHDOG', 'lux_core restart after $failCount health failures');
          try {
            await coreManager!.restart();
            appLog('WATCHDOG', 'lux_core restarted');
            failCount = 0;
          } catch (e) {
            appLog('WATCHDOG', 'lux_core restart failed: $e');
          }
        } else if (failCount >= 6) {
          // Six failures (~3 min) — lux_core unrecoverable, relaunch entire app
          appLog('WATCHDOG', 'relaunching Lux.app after $failCount persistent failures');
          await _relaunchApp();
        }
        return mounted;
      } catch (e) {
        // API itself unreachable — lux_core crashed or hung
        failCount++;
        appLog('WATCHDOG', 'lux_core unreachable ($failCount): $e');
        if (failCount == 3) {
          await NetworkReset.reset();
          try {
            await coreManager!.restart();
            appLog('WATCHDOG', 'lux_core restarted after API timeout');
            failCount = 0;
          } catch (restartErr) {
            appLog('WATCHDOG', 'restart failed: $restartErr');
          }
        } else if (failCount >= 5) {
          // API completely unreachable for 2.5+ min — relaunch
          appLog('WATCHDOG', 'API unreachable ${failCount}x — relaunching Lux.app');
          await _relaunchApp();
        }
        return mounted;
      }
    });
  }

  void _onCoreReady(AppStateModel appState) {
    // Set ValueNotifier directly — don't wrap in setState as that can be
    // deferred on macOS when the window hasn't been shown yet (background launch).
    // The ValueNotifier notifies its listeners immediately regardless of widget state.
    isCoreReady.value = true;
    appLog('CORE', '_onCoreReady fired isCoreReady=true');
    // Trigger a UI rebuild separately if the widget is mounted
    if (mounted) setState(() {});
    // On macOS silent start, hide the window now that lux_core is ready.
    // We waited until here (instead of hiding at startup) because macOS Sequoia
    // requires the window to be visible for Flutter engine to fully initialize.
    if (widget.silentStart && Platform.isMacOS) {
      _hideWindow();
    }
    // After core starts, probe for a network proxy in the background.
    // Wait 3s for lux_core to fully initialize its HTTP routes.
    // If the first check fails (null result / timeout), retry at 20s.
    Future.delayed(const Duration(seconds: 3), () async {
      await _checkForNetworkProxy(force: true);
      // Retry once after 20s in case lux_core was still starting up first time
      await Future.delayed(const Duration(seconds: 20));
      if (mounted) await _checkForNetworkProxy(force: true);
    });
    // Detect corporate vs home network and switch rules accordingly
    Future.delayed(const Duration(seconds: 3), () { _safeDetect(); });
    // On Windows: silently apply UWP loopback exemption in the background.
    // This ensures Windows Store apps can route through lux without requiring the setup wizard.
    if (Platform.isWindows) {
      Future.delayed(const Duration(seconds: 5), _ensureUwpLoopback);
    }
    if (eventChannel == null) {
      coreManager?.getEventChannel().then((channel) async {
        if (channel == null) return;
        // Retry connection — on Windows lux_core's WS server may not be ready
        // immediately after HTTP ping succeeds (errno 1225 = connection refused)
        WebSocketChannel current = channel;
        for (int attempt = 0; attempt < 5; attempt++) {
          try {
            await current.ready;
            break; // connected
          } catch (_) {
            if (attempt < 4) {
              await Future.delayed(Duration(seconds: attempt + 1));
              coreManager?.clearEventChannel();
              final fresh = await coreManager?.getEventChannel();
              if (fresh == null) return;
              current = fresh;
            } else {
              return; // give up — non-critical, app works without event channel
            }
          }
        }
        eventChannel = current;
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
            case 'proxy_expired':
              {
                final expiredId = message['expiredId'] as String? ?? '';
                final fallbackId = message['fallbackId'] as String? ?? '';
                appLog('PROXY', 'password expired for proxy $expiredId'
                    '${fallbackId.isNotEmpty ? " — switched to $fallbackId" : " — no working fallback found"}');
                if (!mounted) return;

                if (fallbackId.isNotEmpty) {
                  // Switched successfully — show a brief notification
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: TText('Proxy password expired — switched to next available proxy'),
                      duration: Duration(seconds: 5),
                      backgroundColor: Colors.orange,
                    ),
                  );
                } else {
                  // No working proxy found — bring Lux to front and alert user
                  await _showWindow();
                  await windowManager.setAlwaysOnTop(true);
                  await Future.delayed(const Duration(milliseconds: 300));
                  await windowManager.setAlwaysOnTop(false);
                  if (!mounted) return;
                  await showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (ctx) => AlertDialog(
                      icon: const Icon(Icons.wifi_off, color: Colors.red, size: 32),
                      title: TText('No Internet Access'),
                      content: const Text(
                        'Your proxy password expired and no working proxy was found.\n\n'
                        'Please select a proxy or enter new credentials to restore internet access.',
                      ),
                      actions: [
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: TText('Go to Proxies'),
                        ),
                      ],
                    ),
                  );
                }
              }
            case 'proxy_auth_failed':
              {
                final proxyId = message['proxyId'] as String? ?? '';
                final proxyName = message['proxyName'] as String? ?? 'proxy';
                appLog('PROXY', 'auth failed for proxy $proxyId ($proxyName)');
                if (!mounted) return;
                await _showWindow();
                await windowManager.setAlwaysOnTop(true);
                await Future.delayed(const Duration(milliseconds: 200));
                await windowManager.setAlwaysOnTop(false);
                if (!mounted) return;
                final displayName = proxyName.isNotEmpty ? proxyName : 'your proxy';
                await showDialog(
                  context: context,
                  barrierDismissible: true,
                  builder: (ctx) => AlertDialog(
                    icon: const Icon(Icons.lock_outline, color: Colors.orange, size: 32),
                    title: TText('Proxy Authentication Failed'),
                    content: Text(
                      'Connection to "$displayName" was rejected (407 Proxy Auth Required).\n\n'
                      'Your password may have changed. Update your credentials to restore internet access.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: TText('Dismiss'),
                      ),
                      if (proxyId.isNotEmpty)
                        FilledButton(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            if (!mounted || coreManager == null) return;
                            final detail = await coreManager!.getProxyDetail(proxyId);
                            if (!mounted || detail == null) return;
                            await showDialog(
                              context: context,
                              builder: (_) => ProxyEditDialog(
                                coreManager: coreManager!,
                                initialValue: detail,
                                onSaved: () {
                                  _refreshTray();
                                },
                              ),
                            );
                          },
                          child: TText('Update Password'),
                        ),
                    ],
                  ),
                );
              }
          }
        });
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      if (!result.contains(ConnectivityResult.none)) {
        appLog('NET', 'connectivity changed: $result — scheduling proxy check in 3s');
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            _checkForNetworkProxy();
            _safeDetect();
          }
          _reconnectIfNeeded();
        });
      } else {
        appLog('NET', 'connectivity lost: $result');
      }
    });
    _listener = AppLifecycleListener(onExitRequested: _handleExitRequest);
    windowManager.addListener(this);
    powerMonitor.addListener(this);
    // Listen for save callbacks from native quick edit panel
    _quickEditChannel.setMethodCallHandler(_handleNativeQuickEdit);
    _init(Provider.of<AppStateModel>(context, listen: false));
  }

  Future<AppExitResponse> _handleExitRequest() async {
    await coreManager?.safeExit();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    powerMonitor.removeListener(this);
    _listener.dispose();
    // NetworkDetector has no resources to dispose
    _networkDetector = null;
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Window closed by user — hide to tray and remove dock icon
    await _hideWindow();
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.setSkipTaskbar(false);
    _showWindow();
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
      await _showWindow();
    } else if (key == 'connect') {
      appLog('PROXY', 'user tapped connect from tray');
      await coreManager?.start();
      _refreshTray();
    } else if (key == 'disconnect') {
      appLog('PROXY', 'user tapped disconnect from tray');
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
    } else if (key == 'check_update') {
      // Open the main window first so the update dialog has a parent
      await _showWindow();
      try {
        final info = await checkForUpdate();
        if (!mounted) return;
        if (info != null && info.hasUpdate) {
          showUpdateDialog(context, info);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Lux ${info?.currentVersion ?? ''} is up to date ✓')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Update check failed: $e')),
          );
        }
      }
    } else if (key == 'exit_app') {
      await coreManager?.exitCore();
      exit(0);
    } else if (key == 'debug_simulate_ssl_bump') {
      await _debugSimulateSslBump(alreadyInstalled: false);
    } else if (key == 'debug_simulate_ssl_bump_installed') {
      await _debugSimulateSslBump(alreadyInstalled: true);
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
    Future.delayed(const Duration(seconds: 3), () { _safeDetect(); });
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
      // Show retry UI instead of crashing — on Windows, UAC timeout can be recovered
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 48, color: Colors.orange),
                const SizedBox(height: 16),
                TText('lux_core failed to start',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('$coreError', style: const TextStyle(fontSize: 12, color: Colors.grey),
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: TText('Retry'),
                  onPressed: () async {
                    setState(() { coreError = null; });
                    try {
                      await coreManager?.run();
                    } catch (e) {
                      if (mounted) setState(() { coreError = e; });
                    }
                  },
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => exit(0),
                  child: TText('Quit'),
                ),
              ],
            ),
          ),
        ),
      );
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
          await _hideWindow();
          await windowManager.setSkipTaskbar(true);
          _refreshTray();
        },
      );
    }
    return Dashboard(homeDir, baseUrl, urlStr, coreManager!,
        onConnected: () {},
        onRegisterProxyRefresh: (cb) => _proxyListRefresh = cb,
        onRefreshTray: _refreshTray);
  }
}
