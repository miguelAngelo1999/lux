import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lux/error.dart';
import 'package:lux/model/app.dart';
import 'package:lux/util/app_log.dart';
import 'package:lux/util/process_manager.dart';
import 'package:lux/util/proxy_env.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../tr.dart';
import '../util/cert_trust.dart';
import '../util/notifier.dart';
import 'core_config.dart';

Future<int> findAvailablePort(int startPort, int endPort) async {
  for (int port = startPort; port <= endPort; port++) {
    try {
      final serverSocket = await ServerSocket.bind("127.0.0.1", port);
      await serverSocket.close();
      return port;
    } catch (e) {
      // Port is not available
    }
  }
  throw Exception('No available port found in range $startPort-$endPort');
}

/// Must be top-level function
Map<String, dynamic> _parseAndDecode(String response) {
  return jsonDecode(response) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> parseJson(String text) {
  return compute(_parseAndDecode, text);
}

class CoreManager {
  final String token;
  final ProcessManager? coreProcess;
  final String baseUrl;

  final Function onReady;
  final AppStateModel appState;
  final Future<List<ConnectivityResult>> Function() _checkConnectivity;
  final Duration _disconnectDebounce;
  final Duration _resumeDebounce;
  final Duration _resumeRetryDelay;
  final Duration _pingTimeout;
  final Duration _pingRetryDelay;
  final bool _isWindows;
  final Future<ProxyMode> Function() _readProxyMode;
  final VoidCallback? onConnectionStateChanged;
  final void Function(String msg)? _showNotification;

  final dio = Dio();
  var needRestart = false;
  bool _isRestartingCore = false;
  bool get isRestartingCore => _isRestartingCore;

  /// Incremented whenever the core daemon restarts or proxy mode changes so
  /// widgets like AppBottomBar can refresh mode badges and reconnect sockets.
  final ValueNotifier<int> coreGeneration = ValueNotifier<int>(0);

  late String baseHttpUrl;
  late String baseWsUrl;
  WebSocketChannel? _trafficChannel;
  WebSocketChannel? _runtimeStatusChannel;
  WebSocketChannel? _eventChannel;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _disconnectTimer;
  Timer? _resumeTimer;
  bool _isResuming = false;

  bool get pausedForNoNetwork => appState.pausedForNoNetwork;
  set pausedForNoNetwork(bool value) => appState.pausedForNoNetwork = value;

  bool get userWantsRunning => appState.userWantsRunning;
  set userWantsRunning(bool value) => appState.userWantsRunning = value;

  /// Returns true when [result] represents active online connectivity
  /// (`wifi`, `ethernet`, `mobile`, `vpn`, `other`, etc.).
  static bool isOnlineConnectivity(List<ConnectivityResult> result) {
    return result.isNotEmpty && !result.contains(ConnectivityResult.none);
  }

  /// Returns true when [e] is the Go core's 403 NotElevated response.
  static bool isNotElevatedError(Object e) {
    if (e is! DioException) return false;
    if (e.response?.statusCode != 403) return false;
    final data = e.response?.data;
    if (data is Map) {
      return data['code'] == coreHttpErrorNotElevatedCode;
    }
    return true;
  }

  CoreManager(
    this.baseUrl,
    this.coreProcess,
    this.token,
    this.onReady, {
    AppStateModel? appState,
    Stream<List<ConnectivityResult>>? connectivityStream,
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
    Duration disconnectDebounce = const Duration(seconds: 2),
    Duration resumeDebounce = const Duration(seconds: 2),
    Duration resumeRetryDelay = const Duration(seconds: 3),
    Duration pingTimeout = const Duration(seconds: 30),
    Duration pingRetryDelay = const Duration(milliseconds: 150),
    bool? isWindowsOverride,
    Future<ProxyMode> Function()? readProxyModeFn,
    this.onConnectionStateChanged,
    void Function(String msg)? showNotification,
  })  : appState = appState ?? AppStateModel(ThemeMode.light, const Locale('en')),
        _checkConnectivity =
            checkConnectivity ?? (() => Connectivity().checkConnectivity()),
        _disconnectDebounce = disconnectDebounce,
        _resumeDebounce = resumeDebounce,
        _resumeRetryDelay = resumeRetryDelay,
        _pingTimeout = pingTimeout,
        _pingRetryDelay = pingRetryDelay,
        _isWindows = isWindowsOverride ?? Platform.isWindows,
        _readProxyMode = readProxyModeFn ?? readProxyMode,
        _showNotification = showNotification {
    baseHttpUrl = "http://$baseUrl";
    baseWsUrl = "ws://$baseUrl";
    dio.transformer = BackgroundTransformer()..jsonDecodeCallback = parseJson;
    dio.options.receiveTimeout = const Duration(seconds: 10);

    // Bypass system proxy for localhost API calls to lux_core.
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (uri) {
          if (uri.host == '127.0.0.1' || uri.host == 'localhost') {
            return 'DIRECT';
          }
          return HttpClient.findProxyFromEnvironment(uri);
        };
        return client;
      },
    );

    dio.interceptors.add(InterceptorsWrapper(onRequest:
        (RequestOptions options, RequestInterceptorHandler handler) async {
      final customHeaders = {
        HttpHeaders.authorizationHeader: 'Bearer $token',
      };
      options.headers.addAll(customHeaders);
      return handler.next(options);
    }));

    final stream = connectivityStream ?? Connectivity().onConnectivityChanged;
    _connectivitySub = stream.listen((List<ConnectivityResult> result) {
      handleConnectivityChanged(result);
      if (kDebugMode) {
        print(result);
      }
    });
  }

  void _notify(String Function() messageBuilder, String fallback) {
    try {
      final msg = buildContext != null ? messageBuilder() : fallback;
      if (_showNotification != null) {
        _showNotification!(msg);
        return;
      }
      if (buildContext == null) return;
      notifier.show(msg);
    } catch (e) {
      debugPrint('notify error: $e');
    }
  }

  /// Cancels any pending disconnect or auto-resume debounce timers.
  void cancelNetworkTimers() {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  /// Releases connectivity subscription and timers.
  void dispose() {
    cancelNetworkTimers();
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  /// Processes an OS connectivity change event.
  void handleConnectivityChanged(List<ConnectivityResult> result) {
    if (result.contains(ConnectivityResult.none)) {
      _resumeTimer?.cancel();
      _resumeTimer = null;

      if (_disconnectTimer?.isActive ?? false) {
        return;
      }
      _disconnectTimer = Timer(_disconnectDebounce, () async {
        _disconnectTimer = null;
        await _handleConfirmedDisconnect();
      });
      return;
    }

    if (isOnlineConnectivity(result)) {
      _disconnectTimer?.cancel();
      _disconnectTimer = null;

      if (pausedForNoNetwork && userWantsRunning) {
        scheduleAutoResume();
      }
    }
  }

  Future<void> _handleConfirmedDisconnect() async {
    try {
      final connectivityResult = await _checkConnectivity();
      if (isOnlineConnectivity(connectivityResult)) {
        return;
      }
      final isStarted = await getIsStarted();
      if (!isStarted) {
        return;
      }
      final setting = await getSetting();
      if (setting.mode == ProxyMode.tun || setting.mode == ProxyMode.mixed) {
        if (!userWantsRunning) {
          await stop();
          appState.updateIsStarted(false);
          onConnectionStateChanged?.call();
          return;
        }
        pausedForNoNetwork = true;
        await stop();
        appState.updateIsStarted(false);
        onConnectionStateChanged?.call();
        _notify(() => tr().noConnectionMsg, 'No available network. Disconnected');
        appLog('NET', 'no connection, paused core (pausedForNoNetwork=true)');
      }
    } catch (e) {
      appLog('NET', 'disconnect handler error: $e');
    }
  }

  /// Debounces auto-resume for DHCP/route settling before starting the core.
  void scheduleAutoResume() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_resumeDebounce, () async {
      _resumeTimer = null;
      await triggerAutoResume();
    });
  }

  /// Attempts to resume Lux after connectivity returns, retrying up to 2 times
  /// while DHCP/routes settle.
  Future<void> triggerAutoResume() async {
    if (_isResuming) return;
    if (!pausedForNoNetwork || !userWantsRunning) return;

    _isResuming = true;
    try {
      final current = await _checkConnectivity();
      if (!isOnlineConnectivity(current)) {
        appLog('NET', 'auto-resume skipped: still offline ($current)');
        return;
      }

      try {
        if (await getIsStarted()) {
          pausedForNoNetwork = false;
          appState.updateIsStarted(true);
          onConnectionStateChanged?.call();
          return;
        }
      } catch (_) {}

      const maxAttempts = 3; // initial attempt + up to 2 short retries
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        if (!pausedForNoNetwork || !userWantsRunning) {
          appLog('NET', 'auto-resume aborted: cleared or manually stopped');
          return;
        }
        final onlineNow = await _checkConnectivity();
        if (!isOnlineConnectivity(onlineNow)) {
          appLog('NET', 'auto-resume aborted: connectivity lost ($onlineNow)');
          return;
        }

        try {
          await start();
          // Respect a manual OFF that occurred while start() was awaiting.
          if (!userWantsRunning) {
            pausedForNoNetwork = false;
            try {
              await stop();
            } catch (_) {}
            appState.updateIsStarted(false);
            onConnectionStateChanged?.call();
            return;
          }
          pausedForNoNetwork = false;
          appState.updateIsStarted(true);
          onConnectionStateChanged?.call();
          _notify(() => tr().reconnectedMsg, 'Reconnected');
          appLog('NET', 'auto-resumed core on attempt $attempt/$maxAttempts');
          return;
        } catch (e) {
          appLog('NET', 'auto-resume attempt $attempt/$maxAttempts failed: $e');
          if (attempt < maxAttempts) {
            await Future.delayed(_resumeRetryDelay);
          }
        }
      }
    } finally {
      _isResuming = false;
    }
  }

  /// User-initiated stop (UI toggle or tray menu). Clears both
  /// [pausedForNoNetwork] and [userWantsRunning] so manual OFF is always respected.
  Future<void> manualStop() async {
    cancelNetworkTimers();
    pausedForNoNetwork = false;
    userWantsRunning = false;
    await stop();
    appState.updateIsStarted(false);
    onConnectionStateChanged?.call();
  }

  /// Shared start/stop toggle used by both the header switch and the
  /// ProxiesPage status banner's Connect button.
  Future<bool> toggleConnection(bool shouldStart) async {
    appState.pausedForNoNetwork = false;
    appState.userWantsRunning = shouldStart;
    cancelNetworkTimers();
    bool succeeded = false;
    try {
      if (shouldStart) {
        // Do not wrap start() in a fixed outer timeout: on Windows, switching
        // into Mixed/TUN mode may display an interactive UAC prompt that takes
        // longer than 60s (e.g. corporate admin credentials). Every
        // non-interactive network/process step inside start() has its own
        // bounded timeout.
        await start();
      } else {
        await manualStop().timeout(const Duration(seconds: 30));
      }
      succeeded = true;
    } catch (e) {
      if (e is CoreElevationCancelledError) {
        appState.userWantsRunning = false;
      }
      rethrow;
    } finally {
      bool real = succeeded ? shouldStart : false;
      try {
        real = await getIsStarted();
      } catch (_) {}
      appState.updateIsStarted(real);
      onConnectionStateChanged?.call();
    }
    return appState.isStarted;
  }

  Future<void> makeRequestUntilSuccess(String url) async {
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsed < _pingTimeout) {
      try {
        final response = await dio.get(
          url,
          options: Options(
            sendTimeout: const Duration(seconds: 2),
            receiveTimeout: const Duration(seconds: 2),
          ),
        );

        if (response.statusCode == 200) {
          return;
        }
      } catch (_) {
        debugPrint("fail to connect to core, retry...");
      }
      if (stopwatch.elapsed >= _pingTimeout) {
        break;
      }
      await Future.delayed(_pingRetryDelay);
    }

    throw Exception('timeout');
  }

  Future<void> ping() async {
    try {
      await makeRequestUntilSuccess('$baseHttpUrl/ping');
    } catch (e) {
      throw CoreRunError("fail to ping core: ${e.toString()}");
    }
  }

  /// Queries lux_core's `/is-admin` endpoint to check whether the running
  /// core daemon currently has elevated/administrator privileges.
  Future<bool> isCoreAdmin() async {
    try {
      final res = await dio.get(
        '$baseHttpUrl/is-admin',
        options: Options(
          sendTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 2),
        ),
      );
      if (res.data is Map) {
        return res.data['isAdmin'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    await dio.post('$baseHttpUrl/manager/stop',
        options: Options(
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ));
    // Clear the proxy env vars so Node/Electron tools stop trying to route
    // through a proxy that is no longer running.
    unawaited(clearProxyEnv());
  }

  static String _proxyModeToWire(ProxyMode mode) {
    switch (mode) {
      case ProxyMode.tun:
        return 'tun';
      case ProxyMode.system:
        return 'system';
      case ProxyMode.mixed:
        return 'mixed';
    }
  }

  static ProxyMode _wireToProxyMode(String? mode) {
    switch (mode) {
      case 'tun':
        return ProxyMode.tun;
      case 'system':
        return ProxyMode.system;
      case 'mixed':
      default:
        return ProxyMode.mixed;
    }
  }

  /// On Windows, ensures the running `lux_core.exe` has the privilege level
  /// required by [targetMode] (elevated for TUN/Mixed, non-elevated for System).
  ///
  /// If UAC is cancelled while elevating, respawns a non-elevated core so Lux
  /// stays alive, optionally reverts `setting.mode` back to [revertModeOnCancel]
  /// (and restarts the previous system tunnel if [restartTunnelOnRevert] is
  /// true), then rethrows [CoreElevationCancelledError].
  Future<void> _ensureWindowsCoreElevation({
    required ProxyMode targetMode,
    ProxyMode? revertModeOnCancel,
    bool restartTunnelOnRevert = false,
  }) async {
    if (!_isWindows || coreProcess == null) return;

    final needElevate = targetMode != ProxyMode.system;
    if (needElevate) {
      final alreadyAdmin = await isCoreAdmin();
      if (alreadyAdmin) {
        coreProcess!.needElevate = true;
        return;
      }

      appLog('CORE',
          'mode=$targetMode requires administrator privileges on Windows — restarting lux_core elevated');
      await _restartCoreElevatedWithRecovery(
        revertModeOnCancel: revertModeOnCancel,
        restartTunnelOnRevert: restartTunnelOnRevert,
      );
      return;
    }

    // Downgrade back to non-elevated when switching from TUN/Mixed -> System
    // so HKCU system proxy changes apply to the logged-in standard user.
    if (coreProcess!.needElevate) {
      appLog('CORE',
          'mode=system does not require elevation — restarting lux_core non-elevated');
      coreProcess!.needElevate = false;
      await restartCore();
    }
  }

  Future<void> _restartCoreElevatedWithRecovery({
    ProxyMode? revertModeOnCancel,
    bool restartTunnelOnRevert = false,
  }) async {
    coreProcess!.needElevate = true;
    try {
      await restartCore();
    } on CoreElevationCancelledError {
      appLog('CORE',
          'Windows UAC cancelled — respawning non-elevated lux_core so app stays usable');
      coreProcess!.needElevate = false;
      _isRestartingCore = true;
      try {
        _resetChannels();
        await coreProcess!.run();
        await ping();
        coreGeneration.value++;
        onReady();
      } catch (recoveryErr) {
        appLog('CORE', 'non-elevated recovery spawn failed: $recoveryErr');
      } finally {
        _isRestartingCore = false;
      }

      if (revertModeOnCancel != null) {
        try {
          final current = await dio.get('$baseHttpUrl/setting');
          final raw = Map<String, dynamic>.from(current.data['setting'] as Map);
          raw['mode'] = _proxyModeToWire(revertModeOnCancel);
          await dio.put('$baseHttpUrl/setting', data: raw);
          coreGeneration.value++;
          if (restartTunnelOnRevert && revertModeOnCancel == ProxyMode.system) {
            await dio.post(
              '$baseHttpUrl/manager/start',
              options: Options(
                sendTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
              ),
            );
            appState.updateIsStarted(true);
            onConnectionStateChanged?.call();
          }
        } catch (revertErr) {
          appLog('CORE', 'failed to revert mode after UAC cancel: $revertErr');
        }
      }
      rethrow;
    }
  }

  /// Start the proxy. Retries up to 3 times on 500 (lux_core still initialising)
  /// with exponential backoff: 1s, 2s, 4s.
  ///
  /// On Windows, checks the current proxy mode and elevates `lux_core.exe`
  /// live when TUN/Mixed mode is selected while the core is not elevated.
  Future<void> start() async {
    if (_isWindows && coreProcess != null) {
      ProxyMode proxyMode;
      try {
        final setting = await getSetting();
        proxyMode = setting.mode;
      } catch (_) {
        proxyMode = await _readProxyMode();
      }
      await _ensureWindowsCoreElevation(targetMode: proxyMode);
    }

    // Checksum of the CA bundle before the core rebuilds it on start.
    final caBefore = await caBundleChecksum();
    bool retriedElevation = false;

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        await dio.post('$baseHttpUrl/manager/start',
            options: Options(
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));
        // The core rebuilds the bundle inside /manager/start. Node/Electron
        // apps read it only at launch, so if it changed, tell the user to
        // restart the ones already open.
        unawaited(_notifyIfCaBundleChanged(caBefore));
        // Set HTTP_PROXY/HTTPS_PROXY + NODE_EXTRA_CA_CERTS so Node/Electron
        // tools (Antigravity, VS Code, npm, …) route through lux. Done here —
        // the single funnel every start path goes through (toggle, tray,
        // auto-connect, watchdog, wake) — so it can never be missed. Fire and
        // forget: a slow launchctl/powershell call must not delay start.
        unawaited(applyProxyEnv());
        // Offer to trust the proxy's bump CA if the system does not trust it
        // yet. Silent when already trusted, when the proxy needs a login we
        // do not have, or when the user already skipped it this session.
        unawaited(checkCertTrustOnConnect());
        return; // success
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (_isWindows &&
            coreProcess != null &&
            !retriedElevation &&
            isNotElevatedError(e)) {
          retriedElevation = true;
          appLog('CORE',
              'start() received 403 NotElevated — elevating lux_core and retrying');
          await _restartCoreElevatedWithRecovery();
          continue;
        }
        if (status == 500 && attempt < 3) {
          // lux_core may still be initialising — wait and retry
          appLog('CORE', 'start() got 500, retrying in ${attempt}s (attempt $attempt/3)');
          await Future.delayed(Duration(seconds: attempt));
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _notifyIfCaBundleChanged(String? before) async {
    try {
      final after = await caBundleChecksum();
      if (after == null || after == before) return;
      appLog('CORE', 'CA bundle changed ($before -> $after), notifying');
      await notifier.show(
          'Certificates changed. Restart Node/Electron apps '
          '(Antigravity, VS Code, Slack…) so they trust them.');
    } catch (e) {
      appLog('CORE', 'CA bundle change check failed: $e');
    }
  }

  /// Set when the selected proxy presents a certificate the system does not
  /// trust. The UI (home.dart) listens, shows the dialog, then clears it.
  final ValueNotifier<CertPromptRequest?> certPrompt = ValueNotifier(null);

  /// "proxyId:sha256" pairs already offered this session. Stops the dialog
  /// from reappearing on every watchdog restart or after a Skip.
  final Set<String> _certPromptOffered = {};

  /// After a successful start, checks whether the selected HTTP proxy bumps
  /// TLS with a CA the system does not trust, and if so raises [certPrompt].
  /// Never throws: any failure (407, offline, PAC-only proxy) stays silent.
  Future<void> checkCertTrustOnConnect() async {
    try {
      final list = await getProxyList();
      final item = list.proxies.where((p) => p.id == list.id).firstOrNull;
      if (item == null) return;
      var server = item.server ?? '';
      var port = item.port ?? 0;
      // CONNECT-based probe only works for HTTP proxies.
      if (item.type != 'http') return;
      // PAC-only proxy: no server of its own, so probe the upstream its PAC
      // picks for an external HTTPS site (resolved by lux_core).
      if (server.isEmpty && (item.pacUrl ?? '').isNotEmpty) {
        final up = await getPacUpstream(item.id);
        if (up == null) return;
        server = up.server;
        port = up.port;
      }
      if (server.isEmpty || port == 0) return;

      final detail = await getProxyDetail(item.id);
      final username = detail?.raw['username'] as String? ?? '';
      final password = detail?.password ?? item.password ?? '';

      final cert = await checkCert(
        server: server,
        port: port,
        username: username,
        password: password,
      );
      // intercepted == true means the leaf did NOT verify against the system
      // roots, i.e. not trusted yet. Trusted or no bump => nothing to ask.
      if (!cert.intercepted || cert.pem.isEmpty) return;

      // Pre-check: if already installed in system root store, do not show prompt / mark healthy
      final thumbprint = extractCertThumbprintSha1(cert.pem);
      if (thumbprint != null && await isCertInSystemStore(thumbprint: thumbprint)) {
        appLog('CERT', 'proxy ${item.name} CA ($thumbprint) already in system root store; skipping prompt');
        return;
      }

      final key = '${item.id}:${cert.sha256}';
      if (!_certPromptOffered.add(key)) return;

      appLog('CERT', 'proxy ${item.name} presents untrusted CA ${cert.issuer}; prompting');
      certPrompt.value = CertPromptRequest(
        proxyId: item.id,
        proxyName: item.name,
        server: server,
        port: port,
        username: username,
        password: password,
        cert: cert,
      );
    } catch (e) {
      appLog('CERT', 'connect-time cert check skipped: $e');
    }
  }

  /// Installs the CA from [req] using the proven CLI installer method and re-checks.
  /// Returns true when the system now trusts the proxy certificate.
  Future<bool> trustCertFromPrompt(CertPromptRequest req) async {
    // 1. Execute proven CLI trust installation
    await trustProxyCertificate(proxyHost: req.server, pem: req.cert.pem);

    // 2. Notify lux_core in-memory pool so Go immediately trusts the new root
    try {
      await installCert(req.cert.pem);
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Immediately re-test the proxy connection
    try {
      await getProxyDelay(req.proxyId);
    } catch (_) {}

    try {
      final recheck = await checkCert(
        server: req.server,
        port: req.port,
        username: req.username,
        password: req.password,
      );
      return !recheck.intercepted;
    } catch (_) {
      return true;
    }
  }

  Future<bool> getIsStarted() async {
    final managerRes = await dio.get('$baseHttpUrl/manager',
        options: Options(
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ));
    var isStarted = managerRes.data['isStarted'];
    if (isStarted is bool) {
      return isStarted;
    }
    return false;
  }

  Future<String> getCurProxyInfo() async {
    final managerRes = await dio.get('$baseHttpUrl/proxies/cur-proxy');
    var name = managerRes.data['name'];
    if (name is String && name.isNotEmpty) {
      return name;
    }
    var addr = managerRes.data['addr'];
    if (addr is String && addr.isNotEmpty) {
      return addr;
    }
    return "";
  }

  Future<ProxyList> getProxyList() async {
    final proxiesRes = await dio.get('$baseHttpUrl/proxies');
    return ProxyList.fromJson(proxiesRes.data);
  }

  Future<RuleList> getRuleList() async {
    final rulesRes = await dio.get('$baseHttpUrl/rules');
    return RuleList.fromJson(rulesRes.data);
  }

  Future<List<CustomizedRuleItem>> getCustomizedRules() async {
    final res = await dio.get('$baseHttpUrl/rules/customized');
    final items = res.data['items'] as List? ?? [];
    return items
        .map((e) => CustomizedRuleItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Rule groups, in evaluation order.
  Future<List<RuleGroup>> getRuleGroups() async {
    final res = await dio.get('$baseHttpUrl/rules/customized');
    final groups = res.data['groups'] as List? ?? [];
    return groups
        .map((e) => RuleGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addCustomizedRules(List<String> rules) async {
    await dio.put('$baseHttpUrl/rules/customized', data: {'rules': rules});
  }

  Future<void> editCustomizedRule(String oldRule, String newRule) async {
    await dio.post('$baseHttpUrl/rules/customized',
        data: {'oldRule': oldRule, 'newRule': newRule});
  }


  /// Update a rule by its id using the structured PATCH endpoint.
  Future<void> updateRuleById(String id, {
    required String ruleType,
    required String payload,
    required String policy,
    String network = '',
    String? proxyId,
  }) async {
    Map<String, dynamic> policyPayload;
    switch (policy.toUpperCase()) {
      case 'DIRECT':
        policyPayload = {'kind': 'direct'};
      case 'REJECT':
        policyPayload = {'kind': 'reject'};
      case 'PROXY':
        policyPayload = {'kind': 'selected'};
      default:
        policyPayload = {'kind': 'proxy', 'proxyId': proxyId ?? policy};
    }
    await dio.patch('$baseHttpUrl/rules/items/$id', data: {
      'conditions': [{'type': ruleType, 'value': payload}],
      'policy': policyPayload,
      if (network.isNotEmpty) 'network': network,
    });
  }
  // ── Id-based rule mutations ────────────────────────────────────────────────
  //
  // Prefer these over the string variants above. Addressing a rule by its raw
  // string cannot distinguish an enabled rule from a disabled one and breaks as
  // soon as the rule is edited.

  Future<void> deleteRuleById(String id) async {
    await dio.delete('$baseHttpUrl/rules/items/$id');
  }

  Future<void> toggleRuleById(String id) async {
    await dio.post('$baseHttpUrl/rules/items/$id/toggle');
  }

  /// Reorder within a single group. Ids omitted from [ids] keep their previous
  /// relative position rather than being dropped.
  Future<void> reorderRuleIds(String groupId, List<String> ids) async {
    await dio.post('$baseHttpUrl/rules/items/reorder',
        data: {'groupId': groupId, 'ids': ids});
  }

  Future<void> moveRuleToGroup(String id, String groupId) async {
    await dio.post('$baseHttpUrl/rules/items/$id/group',
        data: {'groupId': groupId});
  }

  Future<void> toggleRuleGroup(String groupId) async {
    await dio.patch('$baseHttpUrl/rules/groups/$groupId',
        data: {'toggle': true});
  }

  Future<void> renameRuleGroup(String groupId, String name) async {
    await dio.patch('$baseHttpUrl/rules/groups/$groupId', data: {'name': name});
  }

  Future<RuleGroup> createRuleGroup(String name) async {
    final res =
        await dio.post('$baseHttpUrl/rules/groups', data: {'name': name});
    return RuleGroup.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteRuleGroup(String groupId) async {
    await dio.delete('$baseHttpUrl/rules/groups/$groupId');
  }

  /// Rules that can never match, and rules that cannot be applied.
  Future<RuleDiagnostics> getRuleDiagnostics() async {
    final res = await dio.get('$baseHttpUrl/rules/diagnostics');
    return RuleDiagnostics.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> reorderCustomizedRules(List<String> rules) async {
    await dio.post('$baseHttpUrl/rules/customized/reorder',
        data: {'rules': rules});
  }

  Future<void> toggleCustomizedRule(String rule) async {
    await dio.post('$baseHttpUrl/rules/customized/toggle',
        data: {'rule': rule});
  }

  /// Test proxy latency. Returns delay in ms or -1 on failure.
  Future<int> getProxyDelay(String id) => testProxyDelay(id);

  Future<int> testProxyDelay(String id) async {
    try {
      final res = await dio.get('$baseHttpUrl/proxies/delay/$id',
          options: Options(receiveTimeout: const Duration(seconds: 13)));
      return res.data['delay'] as int? ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Test proxy latency with cert error and detailed error message detection.
  /// Returns (delay, certError, pacOnly, error). delay=-1 on failure.
  Future<({int delay, bool certError, bool pacOnly, String error})> testProxyDelayDetailed(String id) async {
    try {
      final res = await dio.get('$baseHttpUrl/proxies/delay/$id',
          options: Options(receiveTimeout: const Duration(seconds: 13)));
      final delay = res.data['delay'] as int? ?? -1;
      final certError = res.data['certError'] as bool? ?? false;
      final pacOnly = res.data['pacOnly'] as bool? ?? false;
      final error = res.data['error'] as String? ?? '';
      return (delay: delay, certError: certError, pacOnly: pacOnly, error: error);
    } on DioException catch (e) {
      if (e.response?.data is Map) {
        final data = e.response!.data as Map;
        final delay = data['delay'] as int? ?? -1;
        final certError = data['certError'] as bool? ?? false;
        final pacOnly = data['pacOnly'] as bool? ?? false;
        final error = (data['error'] ?? data['message'] ?? e.message ?? '') as String;
        return (delay: delay, certError: certError, pacOnly: pacOnly, error: error);
      }
      return (delay: -1, certError: false, pacOnly: false, error: e.message ?? e.toString());
    } catch (e) {
      return (delay: -1, certError: false, pacOnly: false, error: e.toString());
    }
  }

  Future<void> selectProxy(String id) async {
    await dio.post('$baseHttpUrl/selected/proxy', data: {'id': id});
  }

  // ── Auto-switch ────────────────────────────────────────────────────────────

  /// Notify lux_core that the user manually selected a proxy.
  /// Records the user's intent and sets a 10-min auto-switch suppression hold.
  Future<void> notifyManualSelect(String proxyId, String proxyName) async {
    try {
      await dio.post('$baseHttpUrl/net-switch/manual-select',
          data: {'proxyId': proxyId, 'proxyName': proxyName});
    } catch (_) {}
  }

  /// Trigger an immediate auto-switch probe cycle.
  Future<void> triggerNetSwitch() async {
    try {
      await dio.post('$baseHttpUrl/net-switch/trigger');
    } catch (_) {}
  }

  /// Get the current auto-switch state.
  Future<Map<String, dynamic>> getNetSwitchStatus() async {
    try {
      final res = await dio.get('$baseHttpUrl/net-switch/status',
          options: Options(receiveTimeout: const Duration(seconds: 3)));
      return Map<String, dynamic>.from(res.data as Map);
    } catch (_) {
      return {};
    }
  }

  /// Enable or disable the auto-switch feature in lux_core.
  Future<void> setNetSwitchEnabled(bool enabled) async {
    try {
      await dio.post('$baseHttpUrl/net-switch/config', data: {'enabled': enabled});
    } catch (_) {}
  }

  /// Push the persisted lastUserProxyId into lux_core on startup.
  Future<void> syncNetSwitchConfig(String? lastUserProxyId) async {
    try {
      await dio.post('$baseHttpUrl/net-switch/config',
          data: {'lastUserProxyId': lastUserProxyId ?? ''});
    } catch (_) {}
  }

  // ── Config import / export / edit ───────────────────────────────────────────

  /// Fetch the raw config.json content (for export or edit).
  Future<String> exportConfig() async {
    final res = await dio.get('$baseHttpUrl/config',
        options: Options(responseType: ResponseType.plain));
    return res.data as String;
  }

  /// Replace config.json with [content]. Throws with the server error message
  /// if the content is invalid JSON or not a valid config.
  Future<void> importConfig(String content) async {
    await dio.put('$baseHttpUrl/config',
        data: content,
        options: Options(
          contentType: 'application/json',
          // Send the string as-is; don't let dio re-encode it.
          requestEncoder: (s, _) => utf8.encode(s),
        ));
  }

  Future<void> selectRule(String id) async {
    await dio.post('$baseHttpUrl/selected/rule', data: {'id': id});
  }

  Future<void> exitCore() async {
    if (_isWindows) {
      try {
        await dio.post(
          '$baseHttpUrl/manager/exit',
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );
      } catch (e) {
        debugPrint(e.toString());
      }
      try {
        await coreProcess?.stopManagedServiceCore();
      } catch (_) {}
    }
    try {
      coreProcess?.exit();
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> safeExit() async {
    try {
      await dio.post(
        '$baseHttpUrl/manager/exit',
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      if (_isWindows) {
        await coreProcess?.stopManagedServiceCore();
      }
      coreProcess?.exit();
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  void _resetChannels() {
    try {
      _trafficChannel?.sink.close();
    } catch (_) {}
    _trafficChannel = null;
    try {
      _runtimeStatusChannel?.sink.close();
    } catch (_) {}
    _runtimeStatusChannel = null;
    try {
      _eventChannel?.sink.close();
    } catch (_) {}
    _eventChannel = null;
  }

  void clearTrafficChannel() {
    _trafficChannel = null;
  }

  void clearEventChannel() {
    _eventChannel = null;
  }

  /// Gracefully shuts down the currently running core so that even an elevated
  /// `lux_core.exe` on Windows releases its HTTP port and single-instance mutex
  /// before a replacement process is spawned.
  Future<void> _stopAndExitRunningCore() async {
    if (await isAlive()) {
      try {
        await dio.post(
          '$baseHttpUrl/manager/exit',
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );
      } catch (_) {
        // Expected: /manager/exit calls os.Exit(0) without writing a response.
      }

      // Wait briefly for the old core to finish closing and release the port
      // and Global\LuxCoreSingleInstanceMutex before spawning the replacement.
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (DateTime.now().isBefore(deadline)) {
        if (!await isAlive()) break;
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    if (_isWindows) {
      try {
        await coreProcess?.stopManagedServiceCore();
      } catch (_) {}
    }
    try {
      coreProcess?.exit();
    } catch (_) {}
  }

  /// Fully restarts the lux_core OS daemon, waits for it to respond to /ping,
  /// and fires onReady() to reconnect WebSockets and app state.
  Future<void> restartCore() async {
    _isRestartingCore = true;
    try {
      _resetChannels();
      await _stopAndExitRunningCore();
      await coreProcess?.run();
      await ping();
      coreGeneration.value++;
      onReady();
    } finally {
      _isRestartingCore = false;
    }
  }

  Future<void> restart() async {
    await restartCore();
  }

  Future<bool> isAlive() async {
    try {
      final res = await dio.get('$baseHttpUrl/ping',
          options: Options(
            sendTimeout: const Duration(seconds: 2),
            receiveTimeout: const Duration(seconds: 2),
          ));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> ensureCoreRunning() async {
    final alive = await isAlive();
    if (!alive) {
      appLog('CORE', 'lux_core unreachable — restarting process');
      await restartCore();
    }
  }

  Future<void> run() async {
    await coreProcess?.run();
    await ping();
    coreGeneration.value++;
    onReady();
  }

  Future<WebSocketChannel?> getTrafficChannel() async {
    _trafficChannel ??=
        WebSocketChannel.connect(Uri.parse('$baseWsUrl/traffic?token=$token'));

    return _trafficChannel;
  }

  Future<WebSocketChannel?> getRuntimeStatusChannel() async {
    _runtimeStatusChannel ??= WebSocketChannel.connect(
        Uri.parse('$baseWsUrl/heartbeat/runtime-status?token=$token'));

    return _runtimeStatusChannel;
  }

  void clearRuntimeStatusChannel() {
    _runtimeStatusChannel = null;
  }

  Future<WebSocketChannel?> getEventChannel() async {
    _eventChannel ??=
        WebSocketChannel.connect(Uri.parse('$baseWsUrl/event?token=$token'));

    return _eventChannel;
  }

  Future<Setting> getSetting() async {
    final res = await dio.get('$baseHttpUrl/setting');
    if (!(res.data.containsKey('setting') &&
        res.data['setting'] is Map<String, dynamic>)) {
      throw Exception('invalid setting data');
    }
    return Setting.fromJson(res.data["setting"]);
  }

  Future<void> deleteProxies(List<String> ids) async {
    await dio.delete('$baseHttpUrl/proxies', data: {'ids': ids});
  }

  Future<SubscriptionList> getSubscriptionList() async {
    final res = await dio.get('$baseHttpUrl/subscription/all');
    return SubscriptionList.fromJson(res.data);
  }

  /// Fetches the full proxy detail including password for a given proxy ID.
  Future<ProxyDetail?> getProxyDetail(String id) async {
    try {
      final res = await dio.get('$baseHttpUrl/proxies/$id');
      if (res.data is Map<String, dynamic>) {
        return ProxyDetail.fromJson(res.data);
      }
      return null;
    } catch (e) {
      debugPrint('Failed to get proxy detail: $e');
      return null;
    }
  }

  /// Locks a proxy's password so it can never be revealed again.
  Future<void> lockProxyPassword(String id) async {
    await dio.post('$baseHttpUrl/proxies/$id/lock-password');
  }

  /// Resets a proxy's password (wipes it and removes lock).
  Future<void> resetProxyPassword(String id) async {
    await dio.post('$baseHttpUrl/proxies/$id/reset-password');
  }

  /// Creates a new proxy and returns its ID.
  Future<String> addProxy(Map<String, dynamic> proxy) async {
    final sanitized = Map<String, dynamic>.from(proxy);
    if (sanitized['server'] is String) sanitized['server'] = (sanitized['server'] as String).trim();
    if (sanitized['username'] is String) sanitized['username'] = (sanitized['username'] as String).trim();
    if (sanitized['name'] is String) sanitized['name'] = (sanitized['name'] as String).trim();
    final res = await dio.put('$baseHttpUrl/proxies', data: sanitized);
    return res.data['id'] as String;
  }

  /// Probes the network for a PAC URL and returns discovered proxy entries.
  /// Retries once on failure - first call after startup can timeout while
  /// PowerShell cold-starts on Windows.
  Future<DetectProxyResult> detectProxies() async {
    try {
      final res = await dio.post('$baseHttpUrl/proxies/detect');
      return DetectProxyResult.fromJson(res.data as Map<String, dynamic>);
    } catch (_) {
      await Future.delayed(const Duration(seconds: 2));
      final res = await dio.post('$baseHttpUrl/proxies/detect');
      return DetectProxyResult.fromJson(res.data as Map<String, dynamic>);
    }
  }


  /// Fetches and parses the PAC script for a proxy.
  /// Returns an empty rules list if the proxy has no pacUrl.
  Future<PACRulesResult> getPACRules(String proxyId) async {
    final res = await dio.get('$baseHttpUrl/proxies/$proxyId/pac-rules',
        options: Options(receiveTimeout: const Duration(seconds: 30)));
    return PACRulesResult.fromJson(res.data as Map<String, dynamic>);
  }

  /// Evaluates a test URL or domain against the proxy's PAC script.
  Future<PACTestResult> testPACUrl(String proxyId, String url) async {
    final res = await dio.post('$baseHttpUrl/proxies/$proxyId/pac-test',
        data: {'url': url},
        options: Options(receiveTimeout: const Duration(seconds: 15)));
    return PACTestResult.fromJson(res.data as Map<String, dynamic>);
  }

  /// Checks for SSL interception through a proxy by doing a TLS handshake.
  Future<CertCheckResult> checkCert({
    required String server,
    required int port,
    String username = '',
    String password = '',
  }) async {
    final res = await dio.post('$baseHttpUrl/proxies/check-cert', data: {
      'server': server,
      'port': port,
      'username': username,
      'password': password,
    });
    return CertCheckResult.fromJson(res.data as Map<String, dynamic>);
  }

  /// Asks lux_core which HTTP upstream a PAC-only proxy's PAC selects for an
  /// external HTTPS site. Null when the PAC says DIRECT or is not loaded.
  Future<({String server, int port})?> getPacUpstream(String proxyId) async {
    try {
      final res = await dio.get('$baseHttpUrl/proxies/$proxyId/pac-upstream');
      final data = res.data;
      if (data is Map && data['found'] == true) {
        final server = data['server'] as String? ?? '';
        final port = data['port'] as int? ?? 0;
        if (server.isNotEmpty && port > 0) return (server: server, port: port);
      }
    } catch (e) {
      appLog('CERT', 'pac-upstream lookup failed: $e');
    }
    return null;
  }

  /// Installs a PEM certificate to the System Keychain via lux_core (runs as root).
  Future<void> installCert(String pem) async {
    try {
      final res = await dio.post('$baseHttpUrl/proxies/install-cert', data: {'pem': pem});
      if (res.data is Map && res.data['success'] != true) {
        throw Exception(res.data['error'] ?? 'cert install failed');
      }
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] != null) {
        throw Exception(data['error'].toString().trim());
      }
      rethrow;
    }
  }

  /// Updates an existing proxy.
  Future<void> updateProxy(String id, Map<String, dynamic> proxy) async {
    final sanitized = Map<String, dynamic>.from(proxy);
    if (sanitized['server'] is String) sanitized['server'] = (sanitized['server'] as String).trim();
    if (sanitized['username'] is String) sanitized['username'] = (sanitized['username'] as String).trim();
    if (sanitized['name'] is String) sanitized['name'] = (sanitized['name'] as String).trim();
    await dio.post('$baseHttpUrl/proxies/$id', data: sanitized);
  }

  /// Alias for [saveSetting] for consistency with Go API naming.
  Future<void> setSetting(Setting setting) => saveSetting(setting);

  /// Save settings — reads current raw config and merges only the changed fields.
  /// Never overwrites DNS server lists or other fields not managed by the settings page.
  Future<void> saveSetting(Setting setting) async {
    final current = await dio.get('$baseHttpUrl/setting');
    final raw = Map<String, dynamic>.from(current.data['setting'] as Map);

    // Detect a proxy-mode change. The Go core reads setting.mode only when the
    // manager (re)starts (executor.New), and only Close() tears down the old
    // mode's OS state (TUN device / system-proxy entries). So a mode change
    // must be applied with a stop→start while running — otherwise it silently
    // does nothing until a full app restart.
    final prevMode = raw['mode'] as String?;
    final newMode = setting.mode == ProxyMode.tun
        ? 'tun'
        : setting.mode == ProxyMode.system
            ? 'system'
            : 'mixed';
    final modeChanged = prevMode != null && prevMode != newMode;

    // Only update fields the settings page manages
    raw['mode'] = newMode;
    raw['autoLaunch'] = setting.autoLaunch;
    raw['autoConnect'] = setting.autoConnect;
    raw['defaultInterface'] = setting.defaultInterface;

    // Local server — preserve existing structure
    final ls = Map<String, dynamic>.from(raw['localServer'] as Map? ?? {});
    ls['port'] = setting.localServerPort;
    ls['allowLan'] = setting.allowLan;
    raw['localServer'] = ls;

    raw['bypassCidrs'] = setting.bypassCidrs;

    if (setting.blockQuic != null) raw['blockQuic'] = setting.blockQuic;
    if (setting.shouldFindProcess != null) raw['shouldFindProcess'] = setting.shouldFindProcess;
    if (setting.sensitiveInfoMode != null) raw['sensitiveInfoMode'] = setting.sensitiveInfoMode;

    // DNS — only update fakeIp and disableCache, NEVER touch server lists
    final dns = Map<String, dynamic>.from(raw['dns'] as Map? ?? {});
    if (setting.fakeIp != null) dns['fakeIp'] = setting.fakeIp;
    if (setting.disableDnsCache != null) dns['disableCache'] = setting.disableDnsCache;
    raw['dns'] = dns;

    // HijackDns — preserve networkService and alwaysReset
    final hd = Map<String, dynamic>.from(raw['hijackDns'] as Map? ?? {});
    hd['enabled'] = setting.hijackDns;
    raw['hijackDns'] = hd;

    // AutoMode
    final am = Map<String, dynamic>.from(raw['autoMode'] as Map? ?? {});
    am['enabled'] = setting.autoModeEnabled;
    am['type'] = setting.autoModeType;
    am['url'] = setting.autoModeUrl;
    raw['autoMode'] = am;

    await dio.put('$baseHttpUrl/setting', data: raw);

    // Apply a mode change live: if the core is running, restart the tunnel so
    // the old mode tears down (TUN device / system-proxy restored) and the new
    // mode is built by executor.New(). On Windows, switching System -> TUN/Mixed
    // also restarts lux_core.exe elevated (triggering UAC) before starting the
    // new mode, and reverts cleanly to the previous mode if UAC is cancelled.
    if (modeChanged) {
      final running = await getIsStarted();
      if (running) {
        appLog('CORE', 'mode changed $prevMode→$newMode — restarting tunnel');
        await stop();
        // Brief gap so the old mode's teardown (utun remove / networksetup /
        // Windows system-proxy restore) completes under the previous privilege
        // context before elevating or starting the new mode.
        await Future.delayed(const Duration(milliseconds: 500));
        if (_isWindows && coreProcess != null) {
          await _ensureWindowsCoreElevation(
            targetMode: setting.mode,
            revertModeOnCancel: _wireToProxyMode(prevMode),
            restartTunnelOnRevert: true,
          );
        }
        await start();
      }
      coreGeneration.value++;
    }
  }

  /// Get available network interfaces.
  Future<List<String>> getSettingInterfaces() async {
    try {
      final res = await dio.get('$baseHttpUrl/setting/interfaces');
      final ifaces = res.data['interfaces'] as List? ?? [];
      return ifaces.map((e) {
        final name = (e as Map)['Name'] as String? ?? '';
        final friendly = e['FriendlyName'] as String? ?? '';
        return friendly.isNotEmpty ? '$friendly ($name)' : name;
      }).where((s) => s.isNotEmpty).toList().cast<String>();
    } catch (_) {
      return [];
    }
  }

  /// Get log WebSocket channel (reconnectable).
  Future<WebSocketChannel> getLogChannel() async {
    return WebSocketChannel.connect(
        Uri.parse('$baseWsUrl/log?token=$token'));
  }

  /// Get connections WebSocket channel (reconnectable).
  Future<WebSocketChannel> getConnectionsChannel() async {
    return WebSocketChannel.connect(
        Uri.parse('$baseWsUrl/connection?token=$token'));
  }

  /// Close all active connections.
  Future<void> closeAllConnections() async {
    await dio.delete('$baseHttpUrl/connection');
  }
}
