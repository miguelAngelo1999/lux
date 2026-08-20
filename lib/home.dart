import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:lux/const/const.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/dashboard.dart';
import 'package:lux/model/app.dart';
import 'package:lux/tr.dart';
import 'package:lux/tray.dart';
import 'package:lux/util/app_log.dart';
import 'package:lux/util/notifier.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/telemetry.dart' as telem;
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
  Timer? _watchdogTimer;
  // True when the user has explicitly started the core (or autoConnect did).
  // The watchdog only restarts when this is true, so a deliberate toggle-off
  // is respected.
  bool _userWantsRunning = false;
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
    var corePath = path.join(Paths.assetsBin.path, LuxCoreName.name);
    var curHomeDir = await getHomeDir();
    await initAppLog(curHomeDir);
    appLog('APP', 'init started homeDir=$curHomeDir');

    // Translations are needed before the first frame that uses TText, and the
    // load is a single bundled asset read.
    await TranslationCache.load();

    // Usage reporting is opt-in; initTelemetry returns immediately when the
    // stored level is off.
    final telemetryLevel = await readTelemetryLevel();
    final telemetryUuid = await readOrCreateTelemetryUuid();
    await telem.initTelemetry(
      uuid: telemetryUuid,
      level: telem.telemetryLevelFromString(telemetryLevel),
    );

    final port = await findAvailablePort(8000, 9000);
    // Stable across restarts on purpose. See readOrCreateApiSecret.
    var secret = await readOrCreateApiSecret();
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
        // If autoConnect fires, mark user intent so watchdog knows to keep it running.
        readAutoConnect().then((v) {
          if (v && mounted) {
            Provider.of<AppStateModel>(context, listen: false).userWantsRunning = true;
          }
        });
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
    if (eventChannel == null) {
      coreManager?.getEventChannel().then((channel) async {
        if (channel == null) return;
        // Required by web_socket_channel 3.x: core events would otherwise be
        // dropped before the socket is open, with no error surfaced.
        await channel.ready;
        if (!mounted) return;
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
            case 'credential-expired':
              {
                final data = message['data'] as Map<String, dynamic>?;
                final proxyIds = (data?['proxyIds'] as List?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    [];
                if (proxyIds.isNotEmpty) {
                  telem.telemetryError('credential-expired',
                      'All proxies exhausted after credential expiry',
                      extra: {'proxyIds': proxyIds});
                  _handleCredentialExpired(proxyIds);
                }
              }
            case 'proxy-switch':
              {
                final data = message['data'] as Map<String, dynamic>?;
                final name = data?['name'] as String? ?? 'another proxy';
                telem.telemetryOp('proxy-switch', 'Switched to $name');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Switched to $name (previous credentials expired)'),
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
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
    // Watchdog: restart the core if it stops unexpectedly while the user
    // had it running. Checks every 30 seconds.
    _watchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) => _watchdog());
  }

  /// Watchdog — restarts the core if it stopped unexpectedly while the user
  /// wanted it running. Runs every 30 seconds.
  Future<void> _watchdog() async {
    if (coreManager == null) return;
    final appState = Provider.of<AppStateModel>(context, listen: false);
    if (!appState.userWantsRunning) return;
    try {
      final isStarted = await coreManager!.getIsStarted();
      if (!isStarted) {
        appLog('WATCHDOG', 'core stopped unexpectedly — restarting');
        await coreManager!.start();
      }
    } catch (_) {
      // Core unreachable — will retry next tick
    }
  }

  /// When proxy credentials expire and ALL proxies are exhausted (the Go side
  /// already tried switching to each one), bring the window to front and show
  /// a dialog prompting for new credentials.
  Future<void> _handleCredentialExpired(List<String> proxyIds) async {
    // The Go side already tried every other proxy and none worked.
    // Bring the window to front immediately.
    await windowManager.show();
    await windowManager.focus();

    if (!mounted) return;

    // Show re-auth dialog with a grace period timer.
    // If ignored for 5 minutes, stop the core to prevent leaking traffic
    // with invalid credentials (some proxies log failed auth attempts).
    final proxyId = proxyIds.first;
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    bool submitted = false;

    // Grace period: auto-disconnect after 5 minutes if dialog is ignored
    final graceTimer = Timer(const Duration(minutes: 5), () {
      if (!submitted && mounted) {
        coreManager?.stop();
        appLog('CRED-EXPIRY', 'grace period elapsed — stopped core');
        final appState = Provider.of<AppStateModel>(context, listen: false);
        appState.userWantsRunning = false;
      }
    });

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.key_off, size: 22, color: Colors.orange),
          SizedBox(width: 8),
          Text('Proxy Credentials Expired'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your timed proxy password has expired and the internet '
              'is unreachable. Enter new credentials to reconnect.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Lux will disconnect in 5 minutes if not re-authenticated.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: usernameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.pop(ctx),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              passwordController.clear();
              usernameController.clear();
              Navigator.pop(ctx);
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Reconnect'),
          ),
        ],
      ),
    );

    final newUsername = usernameController.text;
    final newPassword = passwordController.text;
    usernameController.dispose();
    passwordController.dispose();
    submitted = true;
    graceTimer.cancel();

    if (newPassword.isEmpty) return;

    // Update the proxy credentials via the API
    try {
      final data = <String, dynamic>{'password': newPassword};
      if (newUsername.isNotEmpty) data['username'] = newUsername;
      await coreManager?.updateProxy(proxyId, data);
      // Restart to pick up new credentials
      await coreManager?.restart();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update credentials: $e')),
        );
      }
    }
  }

  Future<AppExitResponse> _handleExitRequest() async {
    if (Platform.isMacOS) {
      await coreManager?.safeExit();
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
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
