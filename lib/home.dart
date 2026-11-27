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
import 'package:lux/error.dart';
import 'package:lux/model/app.dart';
import 'package:lux/tr.dart';
import 'package:lux/tray.dart';
import 'package:lux/util/app_log.dart';
import 'package:lux/util/notifier.dart';
import 'package:lux/util/t_text.dart';
import 'package:lux/util/telemetry.dart' as telem;
import 'package:lux/util/updater.dart'
    show checkForUpdate, showUpdateConfirmDialog;
import 'package:flutter/services.dart';
import 'package:lux/util/process_manager.dart';
import 'package:lux/widget/error/core_run_error_handler.dart';
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
import 'util/cert_trust.dart';

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

/// Coordinates periodic watchdog health checks, offline skipping, and the
/// safety-net auto-resume if an OS connectivity event was missed.
class WatchdogController {
  WatchdogController({
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
    Duration retryDelayBase = const Duration(milliseconds: 500),
    Duration captivePortalMaxPause = const Duration(minutes: 4),
    DateTime Function()? now,
    void Function(String msg)? showNotification,
    VoidCallback? onRecovered,
  })  : _checkConnectivity =
            checkConnectivity ?? (() => Connectivity().checkConnectivity()),
        _retryDelayBase = retryDelayBase,
        _captivePortalMaxPause = captivePortalMaxPause,
        _now = now ?? DateTime.now,
        _showNotification = showNotification,
        _onRecovered = onRecovered;

  final Future<List<ConnectivityResult>> Function() _checkConnectivity;
  final Duration _retryDelayBase;
  final Duration _captivePortalMaxPause;
  final DateTime Function() _now;
  final void Function(String msg)? _showNotification;
  final VoidCallback? _onRecovered;

  int restartFails = 0;
  static const int maxRestarts = 3;

  Future<bool> _isCaptivePortalStillActive(
      CoreManager coreManager, AppStateModel appState) async {
    if (!appState.pausedForCaptivePortal) return false;
    final pausedAt = appState.captivePortalPausedAt;
    if (pausedAt != null &&
        _now().difference(pausedAt) >= _captivePortalMaxPause) {
      appLog('WATCHDOG',
          'pausedForCaptivePortal exceeded ${_captivePortalMaxPause.inMinutes}m ceiling — clearing flag and recovering');
      appState.pausedForCaptivePortal = false;
      return false;
    }
    try {
      final status = await coreManager.getNetSwitchStatus();
      if (status['state'] == 'captive_portal') {
        appLog('WATCHDOG',
            'confirmed lux_core still in captive_portal — skipping tick');
        return true;
      }
      appLog('WATCHDOG',
          'stale pausedForCaptivePortal flag (core state=${status['state']}) — clearing and continuing');
    } catch (e) {
      appLog('WATCHDOG',
          'getNetSwitchStatus failed while pausedForCaptivePortal ($e) — clearing flag to recover');
    }
    appState.pausedForCaptivePortal = false;
    return false;
  }

  Future<void> tick(CoreManager coreManager, AppStateModel appState) async {
    if (!appState.userWantsRunning) return;
    if (coreManager.isRestartingCore) {
      appLog('WATCHDOG', 'core restart/elevation in progress — skipping tick');
      return;
    }
    if (await _isCaptivePortalStillActive(coreManager, appState)) {
      return;
    }

    final connectivityResult = await _checkConnectivity();
    if (!appState.userWantsRunning || appState.pausedForCaptivePortal) {
      return;
    }
    if (!CoreManager.isOnlineConnectivity(connectivityResult)) {
      appLog('WATCHDOG',
          'offline ($connectivityResult) — skipping restart, preserving userWantsRunning');
      return;
    }

    // Safety net: if an OS connectivity event was missed while paused for no
    // network, trigger the auto-resume flow now that connectivity is online.
    if (appState.pausedForNoNetwork) {
      appLog('WATCHDOG',
          'online while pausedForNoNetwork=true — triggering auto-resume');
      await coreManager.triggerAutoResume();
      return;
    }

    bool coreProcessAlive = true;
    bool isStarted = false;
    try {
      isStarted = await coreManager.getIsStarted();
    } catch (e) {
      // Connection refused, timeout, or socket error indicates the daemon is down
      coreProcessAlive = false;
      appLog('WATCHDOG', 'core unreachable ($e) — process appears down');
    }

    if (coreProcessAlive && isStarted) {
      // Healthy — clear the failure streak.
      restartFails = 0;
      return;
    }

    // Core or proxy is down but the user wants it running. Attempt a restart,
    // but cap consecutive failures so a core that cannot stay up (bad config,
    // auth rejected, TUN setup failing) does not loop forever every 30s.
    if (restartFails >= maxRestarts) {
      appLog('WATCHDOG',
          'core failed to stay up after $maxRestarts restarts — giving up');
      appState.userWantsRunning = false;
      restartFails = 0;
      _showNotification?.call(
          'Lux could not stay connected. Check your proxy and credentials, then reconnect.');
      return;
    }

    restartFails++;
    appLog('WATCHDOG',
        'core stopped unexpectedly (daemonDown=${!coreProcessAlive}) — restarting (attempt $restartFails/$maxRestarts)');

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        if (!coreProcessAlive) {
          appLog('WATCHDOG', 'respawning lux_core process (retry $attempt/3)');
          await coreManager.restartCore();
          coreProcessAlive = true;
        }

        await coreManager.start();
        final confirmed = await coreManager.getIsStarted();
        if (confirmed) {
          appLog('WATCHDOG',
              'core reconnected and proxy running on attempt $attempt');
          restartFails = 0;
          appState.updateIsStarted(true);
          _onRecovered?.call();
          return;
        }
      } catch (err) {
        if (err is CoreElevationCancelledError ||
            CoreManager.isNotElevatedError(err)) {
          appLog('WATCHDOG',
              'elevation required or cancelled ($err) — stopping retries');
          appState.userWantsRunning = false;
          restartFails = 0;
          _showNotification?.call(
              'Administrator permission is required for Mixed/TUN mode.');
          return;
        }
        appLog('WATCHDOG', 'restart attempt $attempt failed: $err');
        if (attempt < 3) {
          await Future.delayed(_retryDelayBase * attempt);
        }
      }
    }
  }
}

/// Applies a `net_switch` WebSocket event from `lux_core` to [appState] and
/// returns the optional notification message to display.
///
/// Extracted as a top-level helper so captive-portal pause/resume state
/// transitions can be unit-tested directly without spinning up the full Home UI.
String? applyNetSwitchEvent(
  Map<String, dynamic> data,
  AppStateModel appState, {
  VoidCallback? onConnectionStateChanged,
  VoidCallback? onCaptiveResumeFailed,
}) {
  // Never let a late/in-flight net_switch event override a deliberate manual OFF.
  if (!appState.userWantsRunning) {
    appState.pausedForCaptivePortal = false;
    return null;
  }

  final state = data['state'] as String? ?? '';
  final proxyName = data['proxyName'] as String? ?? '';
  final portalUrl =
      (data['portalUrl'] ?? data['captivePortalUrl']) as String? ?? '';
  final resumed = data['resumed'] == true;

  switch (state) {
    case 'captive_portal':
      appState.pausedForCaptivePortal = true;
      appState.captivePortalUrl = portalUrl;
      appState.updateIsStarted(false);
      onConnectionStateChanged?.call();
      return 'Captive Wi-Fi detected — sign in; Lux will resume automatically';
    case 'corporate':
      final wasCaptive = appState.pausedForCaptivePortal;
      appState.pausedForCaptivePortal = false;
      if (wasCaptive || resumed) {
        appState.updateIsStarted(true);
      }
      appState.bumpProxyList();
      onConnectionStateChanged?.call();
      if (wasCaptive || resumed) {
        return proxyName.isNotEmpty
            ? 'Lux resumed via $proxyName'
            : 'Lux resumed';
      }
      return proxyName.isNotEmpty
          ? 'Proxy switched to $proxyName'
          : 'Proxy switched';
    case 'direct':
      final wasCaptive = appState.pausedForCaptivePortal;
      appState.pausedForCaptivePortal = false;
      if (wasCaptive || resumed) {
        appState.updateIsStarted(true);
      }
      appState.bumpProxyList();
      onConnectionStateChanged?.call();
      return 'No proxy reachable — using direct connection';
    case 'no_internet':
      final wasCaptive = appState.pausedForCaptivePortal;
      appState.pausedForCaptivePortal = false;
      if (wasCaptive) {
        appState.updateIsStarted(resumed);
        if (!resumed && appState.userWantsRunning) {
          // Handoff to auto-resume so Lux comes back once Wi-Fi returns.
          appState.pausedForNoNetwork = true;
          onCaptiveResumeFailed?.call();
        }
        onConnectionStateChanged?.call();
      }
      return 'No internet connection';
    default:
      return null;
  }
}

/// Handles wake-from-sleep network recovery: if offline at wake, preserves
/// [AppStateModel.userWantsRunning] and marks [AppStateModel.pausedForNoNetwork]
/// so Lux auto-resumes as soon as Wi-Fi/Ethernet associates.
Future<bool> handlePowerWake({
  required CoreManager coreManager,
  required AppStateModel appState,
  required bool needRestart,
  Future<List<ConnectivityResult>> Function()? checkConnectivity,
  VoidCallback? onNoConnection,
}) async {
  final check = checkConnectivity ?? (() => Connectivity().checkConnectivity());
  if (needRestart) {
    final connectivityResult = await check();
    if (!CoreManager.isOnlineConnectivity(connectivityResult)) {
      appState.pausedForNoNetwork = true;
      onNoConnection?.call();
      appLog('WAKE',
          'offline at wake ($connectivityResult) — set pausedForNoNetwork=true');
      return false;
    }
    appState.pausedForNoNetwork = true;
    coreManager.scheduleAutoResume();
    return true;
  }

  if (appState.pausedForNoNetwork && appState.userWantsRunning) {
    final connectivityResult = await check();
    if (CoreManager.isOnlineConnectivity(connectivityResult)) {
      coreManager.scheduleAutoResume();
      return true;
    }
  }
  return false;
}

class _HomeState extends State<Home>
    with TrayListener, WindowListener, PowerMonitorListener {
  String baseUrl = "";
  String urlStr = "";
  String homeDir = "";
  CoreManager? coreManager;
  final GlobalKey<ScaffoldMessengerState> _dashboardMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  ValueNotifier<bool> isCoreReady = ValueNotifier<bool>(false);
  Widget? dashboardWidget;
  WebSocketChannel? eventChannel;
  StreamSubscription? _eventChannelSub;
  late final AppLifecycleListener _listener;
  var needRestart = false;
  dynamic coreError;
  bool _quickEditMode = false;
  Timer? _watchdogTimer;
  late final WatchdogController _watchdogController = WatchdogController(
    showNotification: (msg) {
      if (mounted) {
        notifier.show(tl(context, msg));
      }
    },
    onRecovered: () {
      if (mounted) _refreshTray();
    },
  );
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

  bool _certDialogOpen = false;

  /// Raised by CoreManager.checkCertTrustOnConnect when the selected proxy
  /// uses a CA the system does not trust yet.
  Future<void> _onCertPrompt() async {
    final req = coreManager?.certPrompt.value;
    if (req == null || _certDialogOpen || !mounted) return;
    coreManager!.certPrompt.value = null;
    _certDialogOpen = true;
    try {
      final trust = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.security, size: 20, color: Colors.orange),
            SizedBox(width: 8),
            Flexible(
                child: TText('Certificate not trusted',
                    style: TextStyle(fontSize: 15))),
          ]),
          content: Text(
            '"${req.proxyName}" inspects secure traffic with a certificate '
            'this computer does not trust yet'
            '${req.cert.issuer.isNotEmpty ? ' (${req.cert.issuer})' : ''}.\n\n'
            'Websites will show certificate errors until you trust it. '
            'Trust this certificate now?',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const TText('Skip'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const TText('Trust Certificate'),
            ),
          ],
        ),
      );
      if (trust != true || !mounted) return;
      final messenger =
          _dashboardMessengerKey.currentState ?? ScaffoldMessenger.of(context);
      try {
        final ok = await coreManager!.trustCertFromPrompt(req);
        messenger.showSnackBar(SnackBar(
          duration: Duration(seconds: ok ? 4 : 6),
          content: TText(ok
              ? 'Certificate installed and trusted. Proxy is ready.'
              : 'Certificate installed but still reported untrusted. Try the proxy test on the Proxies page.'),
        ));
      } on CertTrustException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      } catch (e) {
        messenger.showSnackBar(
            SnackBar(content: Text('Certificate installation failed: $e')));
      }
    } finally {
      _certDialogOpen = false;
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
      homeDirArg = '-home_dir="$curHomeDir"';
      // Elevate once via LuxCoreService regardless of saved proxyMode
      // (including System mode) so UWP/Store apps and Mixed/TUN work cleanly;
      // CoreManager.startInitialCore() handles zero-UAC fast path and graceful
      // non-elevated System fallback if UAC is cancelled or previously declined.
      needElevate = true;
    }
    final process = ProcessManager(
        corePath, [homeDirArg, '-port=$port', '-secret=$secret'], needElevate);
    var curBaseUrl = '127.0.0.1:$port';
    var curHttpUrl = 'http://$curBaseUrl';
    var curUrlStr =
        '$curHttpUrl/?client_version=$currentVersion&token=$secret&theme=${appState.theme == ThemeMode.dark ? 'dark' : 'light'}';
    debugPrint("dashboard url: $curUrlStr");
    coreManager = CoreManager(
      curBaseUrl,
      process,
      secret,
      () {
        _onCoreReady(appState);
      },
      appState: appState,
      onConnectionStateChanged: _refreshTray,
    );

    coreManager!.certPrompt.addListener(_onCertPrompt);

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
        // Sync app state with core's actual status on launch
        coreManager?.getIsStarted().then((started) {
          if (mounted && started) {
            final state = Provider.of<AppStateModel>(context, listen: false);
            state.updateIsStarted(true);
            state.userWantsRunning = true;
            _refreshTray();
          }
        }).catchError((_) {});
        _refreshTray();
        // Sync auto-switch config to lux_core on startup
        _syncAutoSwitchOnReady();
        if (Platform.isWindows) {
          _ensureUwpLoopback();
        }
      }
    });
    _launchCore();
  }

  void _launchCore() {
    setState(() {
      coreError = null;
    });
    coreManager?.startInitialCore().catchError((e) {
      if (!mounted) return;
      setState(() {
        coreError = e;
      });
    });
  }

  Future<void> _fallbackToSystemMode() async {
    final mgr = coreManager;
    if (mgr == null || mgr.coreProcess == null) return;
    mgr.coreProcess!.needElevate = false;
    await writeWindowsServiceDeclined(true);
    mgr.appState.updateWindowsLimitedMode(true);
    setState(() {
      coreError = null;
    });
    try {
      await mgr.run();
      final current = await mgr.getSetting();
      if (current.mode != ProxyMode.system) {
        await mgr.saveSetting(current.copyWith(mode: ProxyMode.system));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        coreError = e;
      });
    }
  }

  /// Windows only: UWP loopback exemptions (`CheckNetIsolation.exe`) require
  /// administrator / `LocalSystem` privileges.
  ///
  /// When `lux_core.exe` is running elevated via `LuxCoreService`, `lux_core`
  /// itself owns UWP loopback exemption (`pkg/sysproxy/loopback_windows.go`)
  /// and runs `CheckNetIsolation` as `LocalSystem`, so non-elevated `lux.exe`
  /// must NOT spawn a redundant failing PowerShell pass that swallows stderr.
  Future<void> _ensureUwpLoopback() async {
    if (!Platform.isWindows) return;
    final mgr = coreManager;
    if (mgr == null) return;
    try {
      final coreElevated = await mgr.isCoreAdmin();
      if (coreElevated) {
        appLog('UWP',
            'lux_core is running elevated (LuxCoreService) — UWP loopback exemptions are managed by lux_core');
        return;
      }
      // Core is running non-elevated (limited mode). Running CheckNetIsolation
      // without elevation always fails with Access Denied, so skip cleanly and
      // log the real state rather than hiding errors with 2>$null.
      appLog('UWP',
          'skipping UWP loopback exemption: lux_core is non-elevated (limited mode); enable background service in Settings for Store/iCloud apps');
    } catch (e) {
      appLog('UWP', 'failed to verify core elevation for UWP loopback: $e');
    }
  }

  void _onCoreReady(AppStateModel appState) {
    setState(() {
      isCoreReady.value = true;
    });
    _eventChannelSub?.cancel();
    _eventChannelSub = null;
    eventChannel = null;
    coreManager?.getEventChannel().then((channel) async {
      if (channel == null) return;
      // Required by web_socket_channel 3.x: core events would otherwise be
      // dropped before the socket is open, with no error surfaced.
      await channel.ready;
      if (!mounted) return;
      eventChannel = channel;
      _eventChannelSub = eventChannel?.stream.listen((rawData) async {
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
                  (_dashboardMessengerKey.currentState ??
                          ScaffoldMessenger.of(context))
                      .showSnackBar(
                    SnackBar(
                      content: Text(
                          'Switched to $name (previous credentials expired)'),
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
              }
            case 'net_switch':
              {
                final data = message['data'] as Map<String, dynamic>?;
                if (data == null) break;
                final msg = applyNetSwitchEvent(
                  data,
                  appState,
                  onConnectionStateChanged: _refreshTray,
                  onCaptiveResumeFailed: () => coreManager?.scheduleAutoResume(),
                );
                if (msg != null && mounted) {
                  final proxyName = data['proxyName'] as String? ?? '';
                  final String localized;
                  if (msg.startsWith('Lux resumed via ') &&
                      proxyName.isNotEmpty) {
                    localized = tl(context, 'Lux resumed via {name}')
                        .replaceAll('{name}', proxyName);
                  } else if (msg.startsWith('Proxy switched to ') &&
                      proxyName.isNotEmpty) {
                    localized = tl(context, 'Proxy switched to {name}')
                        .replaceAll('{name}', proxyName);
                  } else {
                    localized = tl(context, msg);
                  }
                  notifier.show(localized);
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
            coreManager?.clearEventChannel();
          },
          onDone: () {
            appLog('EVENT', 'event channel closed');
            eventChannel = null;
            coreManager?.clearEventChannel();
            if (coreManager?.isRestartingCore == true) {
              appLog('EVENT',
                  'event channel closed during controlled core restart — skipping watchdog');
              return;
            }
            if (mounted) {
              final s = Provider.of<AppStateModel>(context, listen: false);
              // If lux_core exited while paused for captive portal, clear the
              // captive flag so watchdog recovery is not stuck.
              s.pausedForCaptivePortal = false;
              if (s.userWantsRunning) {
                appLog('EVENT',
                    'core event channel closed while running — triggering watchdog recovery');
                _watchdog();
              }
            }
          },
          cancelOnError: true,
        );
      }).catchError((Object e) {
        appLog('EVENT', 'event channel connect failed: $e');
        eventChannel = null;
        coreManager?.clearEventChannel();
      });
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

  /// Debounced network probe trigger. Waits 3s after the event to let the
  /// network settle, then asks lux_core to run a probe cycle.
  ///
  /// Fires even when `autoSwitchEnabled` is OFF as long as Lux is running (or
  /// paused for captive portal) — `lux_core` enforces whether direct fallback
  /// is permitted vs. captive-portal-only sign-in assist.
  void _scheduleAutoSwitchTrigger(String reason) {
    _autoSwitchDebounce?.cancel();
    _autoSwitchDebounce = Timer(const Duration(seconds: 3), () async {
      if (coreManager == null || !mounted) return;
      final appState = Provider.of<AppStateModel>(context, listen: false);
      final active = appState.isStarted ||
          appState.userWantsRunning ||
          appState.pausedForCaptivePortal;
      // Never probe while Lux is deliberately stopped, even if autoSwitchEnabled is ON.
      if (!active) return;
      appLog('AUTO-SWITCH', 'trigger: $reason (active=$active)');
      await coreManager!.triggerNetSwitch(reason: reason);
    });
  }

  /// On core ready: push persisted auto-switch config (enabled flag +
  /// lastUserProxyId) into lux_core so the state machine has the right
  /// baseline from the first probe cycle, sync any active captive-portal state,
  /// and run an initial startup probe.
  Future<void> _syncAutoSwitchOnReady() async {
    if (coreManager == null) return;
    final enabled = await readAutoSwitchEnabled();
    final lastId = await readLastUserProxyId();
    await coreManager!.setNetSwitchEnabled(enabled);
    if (lastId != null && lastId.isNotEmpty) {
      await coreManager!.syncNetSwitchConfig(lastId);
    }
    try {
      final status = await coreManager!.getNetSwitchStatus();
      if (mounted) {
        final appState = Provider.of<AppStateModel>(context, listen: false);
        final isCaptive = status['state'] == 'captive_portal' &&
            appState.userWantsRunning;
        appState.pausedForCaptivePortal = isCaptive;
        if (isCaptive) {
          appState.captivePortalUrl =
              (status['captivePortalUrl'] ?? status['portalUrl']) as String?;
          appState.updateIsStarted(false);
          _refreshTray();
        }
      }
    } catch (e) {
      appLog('AUTO-SWITCH', 'startup status sync failed: $e');
    }
    _scheduleAutoSwitchTrigger('startup');
  }

  /// Watchdog — restarts the core if it stopped unexpectedly while the user
  /// wanted it running. Runs every 30 seconds.
  Future<void> _watchdog() async {
    if (coreManager == null) return;
    final appState = Provider.of<AppStateModel>(context, listen: false);
    await _watchdogController.tick(coreManager!, appState);
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
        coreManager?.manualStop();
        appLog('CRED-EXPIRY', 'grace period elapsed — stopped core');
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
    if (Platform.isMacOS || Platform.isWindows) {
      await coreManager?.safeExit();
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _connectivitySub?.cancel();
    _autoSwitchDebounce?.cancel();
    _eventChannelSub?.cancel();
    coreManager?.certPrompt.removeListener(_onCertPrompt);
    coreManager?.dispose();
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
    } else if (key == 'check_updates') {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
      try {
        final info = await checkForUpdate();
        if (!mounted) return;
        if (info != null && info.hasUpdate) {
          await writePendingUpdateVersion(info.latestVersion);
          if (mounted) await showUpdateConfirmDialog(context, info);
        } else {
          await writePendingUpdateVersion(null);
          if (mounted) notifier.show(tl(context, 'You are up to date'));
        }
      } catch (e) {
        if (mounted) notifier.show('Update check failed: $e');
      }
    } else if (key == 'connect') {
      final appState = Provider.of<AppStateModel>(context, listen: false);
      coreManager?.cancelNetworkTimers();
      appState.pausedForNoNetwork = false;
      appState.pausedForCaptivePortal = false;
      appState.userWantsRunning = true;
      try {
        await coreManager?.start();
        if (mounted) {
          appState.updateIsStarted(true);
        }
      } on CoreElevationCancelledError catch (e) {
        appState.userWantsRunning = false;
        notifier.show(e.message);
      } catch (e) {
        appLog('CORE', 'tray connect failed: $e');
        notifier.show(extractErrorMessage(e));
      }
      _refreshTray();
    } else if (key == 'disconnect') {
      final appState = Provider.of<AppStateModel>(context, listen: false);
      _autoSwitchDebounce?.cancel();
      appState.pausedForNoNetwork = false;
      appState.pausedForCaptivePortal = false;
      appState.userWantsRunning = false;
      await coreManager?.manualStop();
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
      coreManager!.cancelNetworkTimers();
      needRestart = true;
      await coreManager!.stop();
      if (mounted) {
        Provider.of<AppStateModel>(context, listen: false)
            .updateIsStarted(false);
      }
    }
  }

  @override
  onPowerMonitorWokeUp() async {
    if (coreManager == null) return;
    final appState = Provider.of<AppStateModel>(context, listen: false);
    final wasNeedRestart = needRestart;
    needRestart = false;
    await handlePowerWake(
      coreManager: coreManager!,
      appState: appState,
      needRestart: wasNeedRestart,
      onNoConnection: () {
        if (buildContext != null) {
          notifier.show(tr().noConnectionMsg);
        }
      },
    );
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
      if (coreError is CoreRunError) {
        final canFallbackToSystem = Platform.isWindows &&
            (coreManager?.coreProcess?.needElevate == true ||
                coreError is CoreElevationCancelledError);
        return CoreRunErrorHandler(
          errorDetail: coreError as CoreRunError,
          onRetry: _launchCore,
          onFallbackToSystemMode:
              canFallbackToSystem ? _fallbackToSystemMode : null,
        );
      }
      throw coreError;
    }
    if (coreManager == null || !isCoreReady.value) {
      final mgr = coreManager;
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppProgressIndicator(),
              if (Platform.isWindows && mgr != null)
                ValueListenableBuilder<bool>(
                  valueListenable: mgr.waitingForWindowsUac,
                  builder: (_, waitingForUac, __) {
                    if (!waitingForUac) return const SizedBox.shrink();
                    return const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: TText(
                        'Waiting for administrator permission...',
                        style: TextStyle(fontSize: 13),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      );
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
    return Dashboard(
      homeDir,
      baseUrl,
      urlStr,
      coreManager!,
      contentMessengerKey: _dashboardMessengerKey,
    );
  }
}
