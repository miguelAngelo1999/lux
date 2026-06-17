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
  ValueNotifier<bool> isCoreReady = ValueNotifier<bool>(false);
  Widget? dashboardWidget;
  WebSocketChannel? eventChannel;
  late final AppLifecycleListener _listener;
  var needRestart = false;
  dynamic coreError;
  bool _quickEditMode = false;
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

  /// Early detection ΓÇö reads system proxy via scutil BEFORE lux_core starts.
  /// Called at app init so the system proxy hasn't been overwritten by Lux yet.
  Future<void> _detectProxyEarly() async {
    if (!mounted) return;
    try {
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
      for (final prefix in ['HTTP', 'HTTPS']) {
        if (settings['${prefix}Enable'] == '1') {
          final host = settings['${prefix}Proxy'] ?? '';
          final port = settings['${prefix}Port'] ?? '8080';
          // Skip Lux's own proxy
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
            if (mounted) _showDetectedProxyDialog(detected);
          });
          return;
        }
      }
    } catch (_) {}
    // Fall back to lux_core detection after it starts
  }

  Future<void> _checkForNetworkProxy() async {
    if (coreManager == null || !mounted) return;
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    try {
      final detected = await coreManager!.detectNetworkProxy();
      if (detected == null || !mounted) return;
      // Always show ΓÇö let user decide
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showDetectedProxyDialog(detected);
      });
    } catch (e) {
      debugPrint('Proxy detection error: $e');
    }
  }

  void _showDetectedProxyDialog(DetectedProxy detected) {
    final source = detected.source == 'scutil'
        ? 'system settings'
        : detected.source == 'wpad'
            ? 'WPAD'
            : 'environment';
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.wifi_find, size: 20),
            SizedBox(width: 8),
            Text('Network Proxy Detected', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A proxy was detected via $source:',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.dns, size: 16),
                  const SizedBox(width: 8),
                  Text(detected.address,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            if (detected.needsAuth) ...[
              const SizedBox(height: 8),
              const Text('ΓÜá This proxy requires authentication.',
                  style: TextStyle(fontSize: 12, color: Colors.orange)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Ignore'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _showAddDetectedProxy(detected);
            },
            child: const Text('Add to Lux'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddDetectedProxy(DetectedProxy detected) async {
    final serverCtrl = TextEditingController(text: detected.host);
    final portCtrl = TextEditingController(text: detected.port);
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final userFocus = FocusNode();
    final passFocus = FocusNode();

    Future<void> doAdd(BuildContext ctx) async {
      Navigator.of(ctx).pop();
      try {
        await coreManager!.addProxy({
          'type': 'http',
          'name': 'Network Proxy (${serverCtrl.text})',
          'server': serverCtrl.text,
          'port': int.tryParse(portCtrl.text) ?? 8080,
          if (userCtrl.text.isNotEmpty) 'username': userCtrl.text,
          if (passCtrl.text.isNotEmpty) 'password': passCtrl.text,
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Proxy added ΓÇö checking for SSL inspectionΓÇª')));
        }
        // After adding proxy, wait for Lux to use it then check for SSL bumping
        Future.delayed(const Duration(seconds: 4), () => _checkSslAfterProxyAdd());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to add proxy: $e')));
        }
      }
    }

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Detected Proxy'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: serverCtrl,
                decoration: const InputDecoration(labelText: 'Server', isDense: true),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(labelText: 'Port', isDense: true),
                keyboardType: TextInputType.number,
                textInputAction: detected.needsAuth ? TextInputAction.next : TextInputAction.done,
                onSubmitted: detected.needsAuth
                    ? (_) => FocusScope.of(ctx).requestFocus(userFocus)
                    : (_) => doAdd(ctx),
              ),
              if (detected.needsAuth) ...[
                const SizedBox(height: 12),
                const Text('This proxy requires authentication:',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                TextField(
                  controller: userCtrl,
                  focusNode: userFocus,
                  decoration: const InputDecoration(labelText: 'Username', isDense: true),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => FocusScope.of(ctx).requestFocus(passFocus),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: passCtrl,
                  focusNode: passFocus,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password', isDense: true),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => doAdd(ctx),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => doAdd(ctx),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  /// After proxy is added, probe for SSL bumping and prompt to install cert.
  Future<void> _checkSslAfterProxyAdd() async {
    if (!mounted || coreManager == null) return;
    try {
      final status = await coreManager!.getSslBumpStatus();
      if (!mounted) return;
      if (status.detected && status.hasCert) {
        _showInlineCertTrustDialog(status);
      }
    } catch (_) {}
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
          Text('Valid: ${info.notBefore} ΓåÆ ${info.notAfter}',
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.success
              ? 'Certificate installed successfully'
              : 'Partial install ΓÇö check Settings ΓåÆ SSL Inspection for details'),
          backgroundColor: result.success ? Colors.green.shade700 : Colors.orange.shade700,
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Install failed: $e')));
    }
  }

  // Reload proxy list and connection state into tray menu
  Future<void> _refreshTray() async {
    if (coreManager == null) return;
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

    // Detect network proxy early ΓÇö before lux_core starts, so system proxy
    // settings still reflect the real upstream proxy (not Lux's own 127.0.0.1)
    Future.delayed(const Duration(milliseconds: 500), () => _detectProxyEarly());

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
  }

  void _onCoreReady(AppStateModel appState) {
    setState(() {
      isCoreReady.value = true;
    });
    // After core starts, probe for a network proxy in the background
    Future.delayed(const Duration(seconds: 2), () => _checkForNetworkProxy());
    if (eventChannel == null) {
      coreManager?.getEventChannel().then((channel) {
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
    return Dashboard(homeDir, baseUrl, urlStr, coreManager!);
  }
}
