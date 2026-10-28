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
import 'package:lux/widget/proxy_edit_dialog.dart';
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
  // Watchdog restart backoff: count consecutive failed auto-restarts. After
  // _maxWatchdogRestarts in a row the watchdog gives up instead of looping
  // forever (the crash-loop seen on 2026-10-20/26), sets userWantsRunning=false
  // and notifies the user. Reset to 0 whenever the core is confirmed running.
  int _watchdogRestartFails = 0;
  static const int _maxWatchdogRestarts = 3;
  // Mirrors AppStateModel.isStarted so the tray tooltip can be refreshed the
  // moment the live connection state changes (auto-connect, watchdog restart,
  // net-switch), not only on explicit user actions. Prevents the tray showing
  // a stale "Disconnected" while actually connected.
  AppStateModel? _appStateForTray;
  bool? _lastTrayConnected;
  void _onAppStateChanged() {
    final s = _appStateForTray;
    if (s == null) return;
    if (_lastTrayConnected == s.isStarted) return;
    _lastTrayConnected = s.isStarted;
    _refreshTray();
  }
  // Connectivity subscription for auto-switch trigger
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  // Auto-switch trigger debounce timer
  Timer? _autoSwitchDebounce;
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
    // Refresh the tray whenever the live connection state changes, so the
    // tooltip never goes stale (false "Disconnected" while connected).
    _appStateForTray = appState;
    _lastTrayConnected = appState.isStarted;
    appState.addListener(_onAppStateChanged);
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
      // Silently exempt all UWP/Store apps (including the Store itself) from
      // Windows network isolation so they can reach lux on 127.0.0.1. Runs in
      // the background a few seconds after startup; no dialog.
      Future.delayed(const Duration(seconds: 5), _ensureUwpLoopback);
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
      // _refreshTray() builds the tray with the real connection state. Do NOT
      // precede it with a bare initSystemTray() — that defaults
      // isConnected:false and flashes a wrong "Disconnected" tooltip.
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
        // Sync auto-switch config to lux_core on startup
        _syncAutoSwitchOnReady();
      }
    });
    coreManager?.run().catchError((e) {
      setState(() {
        coreError = e;
      });
    });
  }

  /// Windows only: exempt every installed UWP/Store app — including the
  /// Microsoft Store app itself — from network isolation (AppContainer
  /// loopback block) so they can reach lux's proxy on 127.0.0.1.
  ///
  /// UWP apps run in an AppContainer that blocks loopback by default, so
  /// without this they cannot talk to a local proxy and appear to have no
  /// internet while lux is the system proxy. `CheckNetIsolation LoopbackExempt`
  /// whitelists each app's package family.
  ///
  /// Runs once in the background — no dialog. Uses `-AllUsers` and
  /// `-PackageTypeFilter All` so provisioned/system packages (the Store,
  /// frameworks) are covered, not just the current user's apps. Batched into a
  /// single PowerShell call rather than spawning CheckNetIsolation hundreds of
  /// times.
  Future<void> _ensureUwpLoopback() async {
    if (!Platform.isWindows) return;
    try {
      appLog('UWP', 'applying loopback exemption for Store apps...');
      final result = await Process.run('powershell.exe', [
        '-noprofile', '-NonInteractive', '-WindowStyle', 'Hidden', '-command',
        // Collect package family names from both the current user and all
        // users (covers the Store itself + provisioned apps), de-duplicate,
        // then exempt each one. Errors per-package are swallowed so one bad
        // package can't abort the batch.
        r'$fams = @(); '
        r'try { $fams += Get-AppxPackage -PackageTypeFilter All | '
        r'Select-Object -ExpandProperty PackageFamilyName } catch {} '
        r'try { $fams += Get-AppxPackage -AllUsers -PackageTypeFilter All | '
        r'Select-Object -ExpandProperty PackageFamilyName } catch {} '
        r'$fams = $fams | Sort-Object -Unique; '
        r'foreach ($f in $fams) { CheckNetIsolation.exe LoopbackExempt -a "-n=$f" 2>$null }',
      ]).timeout(const Duration(seconds: 90));
      appLog('UWP', 'loopback exemption done exit=${result.exitCode}');
    } catch (e) {
      // Non-fatal: the app still works for non-UWP traffic.
      appLog('UWP', 'loopback exemption failed: $e');
    }
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
                  // Rebuild via _refreshTray so the tooltip keeps the REAL
                  // connection state. A bare initSystemTray() defaults
                  // isConnected:false and wrongly showed "Disconnected".
                  _refreshTray();
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
            case 'net_switch':
              {
                final data = message['data'] as Map<String, dynamic>?;
                if (data == null) break;
                final state     = data['state']     as String? ?? '';
                final proxyName = data['proxyName'] as String? ?? '';
                final msg = switch (state) {
                  'corporate'   => proxyName.isNotEmpty
                      ? 'Proxy switched to $proxyName'
                      : 'Proxy switched',
                  'direct'      => 'No proxy reachable — using direct connection',
                  'no_internet' => 'No internet connection',
                  _             => null,
                };
                if (msg != null && mounted) {
                  notifier.show(msg);
                  // Refresh proxy list so UI reflects the new selection
                  // The dashboard re-emits state so the proxies page picks it up
                }
              }
          }
        },
          // When the core restarts (e.g. saving a proxy calls manager.Close()+
          // Start() server-side), this WebSocket drops. Without onError/onDone
          // the resulting stream error was unhandled and escaped to the global
          // PlatformDispatcher handler. Swallow it and drop the stale channel so
          // it reconnects on next core-ready, instead of surfacing a crash-like
          // error to the user.
          onError: (Object e) {
            appLog('EVENT', 'event channel error (core restart?): $e');
            eventChannel = null;
          },
          onDone: () {
            appLog('EVENT', 'event channel closed');
            eventChannel = null;
          },
          cancelOnError: true,
        );
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
    // Subscribe to connectivity changes for auto-switch trigger.
    // Fires on interface changes (WiFi on/off, Ethernet plug/unplug).
    _connectivitySub = Connectivity().onConnectivityChanged.listen((_) {
      _scheduleAutoSwitchTrigger('connectivity-change');
    });
  }

  /// Debounced auto-switch trigger. Waits 3s after the event to let the
  /// network settle, then asks lux_core to run a probe cycle (if enabled).
  void _scheduleAutoSwitchTrigger(String reason) {
    _autoSwitchDebounce?.cancel();
    _autoSwitchDebounce = Timer(const Duration(seconds: 3), () async {
      if (coreManager == null) return;
      final enabled = await readAutoSwitchEnabled();
      if (!enabled) return;
      appLog('AUTO-SWITCH', 'trigger: $reason');
      await coreManager!.triggerNetSwitch();
    });
  }

  /// On core ready: push persisted auto-switch config (enabled flag +
  /// lastUserProxyId) into lux_core so the state machine has the right
  /// baseline from the first probe cycle.
  Future<void> _syncAutoSwitchOnReady() async {
    if (coreManager == null) return;
    final enabled = await readAutoSwitchEnabled();
    await coreManager!.setNetSwitchEnabled(enabled);
    if (enabled) {
      final lastId = await readLastUserProxyId();
      await coreManager!.syncNetSwitchConfig(lastId);
    }
  }

  /// Watchdog — restarts the core if it stopped unexpectedly while the user
  /// wanted it running. Runs every 30 seconds.
  Future<void> _watchdog() async {
    if (coreManager == null) return;
    final appState = Provider.of<AppStateModel>(context, listen: false);
    if (!appState.userWantsRunning) return;
    try {
      final isStarted = await coreManager!.getIsStarted();
      if (isStarted) {
        // Healthy — clear the failure streak.
        _watchdogRestartFails = 0;
        return;
      }

      // Core is down but the user wants it running. Attempt a restart, but cap
      // consecutive failures so a core that cannot stay up (bad config, auth
      // rejected, TUN setup failing) does not loop forever every 30s. The
      // 2026-10-20/26 crash-loop was exactly this: endless "core stopped —
      // restarting" with no ceiling.
      if (_watchdogRestartFails >= _maxWatchdogRestarts) {
        // Give up: stop trying, surface it, and let the user re-enable.
        appLog('WATCHDOG',
            'core failed to stay up after $_maxWatchdogRestarts restarts — giving up');
        appState.userWantsRunning = false;
        _watchdogRestartFails = 0;
        if (mounted) {
          notifier.show(tl(context,
              'Lux could not stay connected. Check your proxy and credentials, then reconnect.'));
        }
        return;
      }

      _watchdogRestartFails++;
      appLog('WATCHDOG',
          'core stopped unexpectedly — restarting (attempt $_watchdogRestartFails/$_maxWatchdogRestarts)');
      await coreManager!.start();
      // Confirm the restart actually took. If it did, the next tick clears the
      // counter; if start() threw, we fall to catch and the counter stands.
    } catch (e) {
      // start()/getIsStarted() failed — count it so we eventually give up
      // instead of silently retrying forever.
      _watchdogRestartFails++;
      appLog('WATCHDOG', 'restart attempt failed: $e');
    }
  }

  /// When proxy credentials expire / stop authenticating and ALL proxies are
  /// exhausted (the Go side already tried switching to each one), bring the
  /// window to front and open the proxy edit dialog focused on the password
  /// field so the user can retype it. A grace timer disconnects if ignored.
  Future<void> _handleCredentialExpired(List<String> proxyIds) async {
    await windowManager.show();
    await windowManager.focus();
    if (!mounted || coreManager == null) return;

    final proxyId = proxyIds.first;

    // Grace period: auto-disconnect after 5 minutes if left unanswered, so we
    // don't keep hammering the proxy with a bad password.
    bool answered = false;
    final graceTimer = Timer(const Duration(minutes: 5), () {
      if (!answered && mounted) {
        coreManager?.stop();
        appLog('CRED-EXPIRY', 'grace period elapsed — stopped core');
        Provider.of<AppStateModel>(context, listen: false).userWantsRunning = false;
      }
    });

    try {
      final detail = await coreManager!.getProxyDetail(proxyId);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => ProxyEditDialog(
          coreManager: coreManager!,
          initialValue: detail,
          focusPasswordForReauth: true,
          // After saving, VALIDATE the new password by actually testing an
          // authenticated request through the proxy (the /proxies/delay test),
          // rather than doing a blind full process restart. The old code did a
          // fire-and-forget restart() whose transient 500 (HTML error page)
          // escaped to the global error handler as the raw "500 + firefox"
          // message, and closed the dialog even on success/failure alike.
          //
          // testProxyDelay returns >=0 when the proxy authenticates and answers,
          // and -1 on any failure (wrong password / 407 / unreachable). On -1 we
          // throw so _save() keeps the dialog open and asks the user to retype.
          reconnectAfterSave: () async {
            final mgr = coreManager;
            if (mgr == null) return;
            // The core's updateProxy already restarted the tunnel manager with
            // the new credentials; give it a beat to come up, then probe.
            await Future.delayed(const Duration(milliseconds: 400));
            final delay = await mgr.testProxyDelay(proxyId);
            if (delay < 0) {
              throw const ReauthFailed();
            }
          },
          onSaved: () {
            answered = true;
          },
        ),
      );
    } finally {
      answered = true;
      graceTimer.cancel();
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
    _connectivitySub?.cancel();
    _autoSwitchDebounce?.cancel();
    _appStateForTray?.removeListener(_onAppStateChanged);
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
    if (coreManager == null) return;
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
    // Wake is the highest-value trigger for auto-switch: laptop closed at
    // home, opened at the office (or vice versa).
    _scheduleAutoSwitchTrigger('wake');
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
