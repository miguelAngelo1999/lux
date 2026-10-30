import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/error.dart';
import 'package:lux/util/app_log.dart';
import 'package:lux/util/process_manager.dart';
import 'package:lux/util/proxy_env.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../tr.dart';
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
  final dio = Dio();
  var needRestart = false;
  late String baseHttpUrl;
  late String baseWsUrl;
  WebSocketChannel? _trafficChannel;
  WebSocketChannel? _runtimeStatusChannel;
  WebSocketChannel? _eventChannel;

  CoreManager(
    this.baseUrl,
    this.coreProcess,
    this.token,
    this.onReady,
  ) {
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

    Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> result) async {
      // Received changes in available connectivity types!

      if (result.contains(ConnectivityResult.none)) {
        await Future.delayed(const Duration(seconds: 2));
        final List<ConnectivityResult> connectivityResult =
            await (Connectivity().checkConnectivity());
        if (!connectivityResult.contains(ConnectivityResult.none)) {
          return;
        }
        var isStarted = await getIsStarted();
        if (!isStarted) {
          return;
        }
        var setting = await getSetting();
        if (setting.mode == ProxyMode.tun || setting.mode == ProxyMode.mixed) {
          await stop();
          notifier.show(tr().noConnectionMsg);
          debugPrint("no connection, stop core");
        }
      }
      if (kDebugMode) {
        print(result);
      }
    });
  }

  Future<void> makeRequestUntilSuccess(String url) async {
    final stopwatch = Stopwatch();
    stopwatch.start(); // Start the stopwatch

    while (stopwatch.elapsedMilliseconds < 30000) {
      try {
        final response = await dio.get(url);

        // Check if the request was successful
        if (response.statusCode == 200) {
          return; // Exit the function if the request succeeds
        } else {
          await makeRequestUntilSuccess(url);
        }
      } catch (e) {
        await Future.delayed(const Duration(milliseconds: 150));
        debugPrint("fail to connect to core, retry...");
      }
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

  /// Start the proxy. Retries up to 3 times on 500 (lux_core still initialising)
  /// with exponential backoff: 1s, 2s, 4s.
  ///
  /// On Windows, re-reads the current proxy mode to determine if elevation
  /// is needed — TUN/Mixed require UAC, System mode does not.
  Future<void> start() async {
    // On Windows, update the elevation flag based on current mode before starting.
    // The ProcessManager is created at app launch with the mode at that time,
    // but the user may have changed mode since then.
    if (Platform.isWindows && coreProcess != null) {
      final proxyMode = await readProxyMode();
      final needElevate = proxyMode != ProxyMode.system;
      if (coreProcess!.needElevate != needElevate) {
        coreProcess!.needElevate = needElevate;
        appLog('CORE', 'start() — updated needElevate=$needElevate for mode=$proxyMode');
      }
    }

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        await dio.post('$baseHttpUrl/manager/start',
            options: Options(
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));
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

  /// Installs the CA from [req] and re-checks. Returns true when the system
  /// now trusts the proxy certificate.
  Future<bool> trustCertFromPrompt(CertPromptRequest req) async {
    await installCert(req.cert.pem);
    await Future.delayed(const Duration(milliseconds: 800));
    try {
      final recheck = await checkCert(
        server: req.server,
        port: req.port,
        username: req.username,
        password: req.password,
      );
      return !recheck.intercepted;
    } catch (_) {
      return false;
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
  Future<int> testProxyDelay(String id) async {
    try {
      final res = await dio.get('$baseHttpUrl/proxies/delay/$id',
          options: Options(receiveTimeout: const Duration(seconds: 10)));
      return res.data['delay'] as int? ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Test proxy latency with cert error detection.
  /// Returns (delay, certError). delay=-1 on failure.
  Future<({int delay, bool certError})> testProxyDelayDetailed(String id) async {
    try {
      final res = await dio.get('$baseHttpUrl/proxies/delay/$id',
          options: Options(receiveTimeout: const Duration(seconds: 10)));
      final delay = res.data['delay'] as int? ?? -1;
      final certError = res.data['certError'] as bool? ?? false;
      return (delay: delay, certError: certError);
    } catch (_) {
      return (delay: -1, certError: false);
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
    if (Platform.isWindows) {
      try {
        await dio.post('$baseHttpUrl/manager/exit');
      } catch (e) {
        debugPrint(e.toString());
      }
    }
    try {
      coreProcess?.exit();
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> safeExit() async {
    try {
      await dio.post('$baseHttpUrl/manager/exit');
      coreProcess?.exit();
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<void> restart() async {
    coreProcess?.exit();
    await coreProcess?.run();
  }

  Future<void> run() async {
    await coreProcess?.run();
    await ping();
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
    final res = await dio.put('$baseHttpUrl/proxies', data: proxy);
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
    final res = await dio.post('$baseHttpUrl/proxies/install-cert', data: {'pem': pem});
    if (res.data['success'] != true) {
      throw Exception(res.data['error'] ?? 'cert install failed');
    }
  }

  /// Updates an existing proxy.
  Future<void> updateProxy(String id, Map<String, dynamic> proxy) async {
    await dio.post('$baseHttpUrl/proxies/$id', data: proxy);
  }

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
    // mode is built by executor.New(). If it's not running, the next start
    // picks up the new mode — no need to connect just because a dropdown
    // changed. lux_core runs elevated via the sudoers wrapper, so no re-spawn
    // or elevation prompt is needed for System↔TUN↔Mixed.
    if (modeChanged) {
      final running = await getIsStarted();
      if (running) {
        appLog('CORE', 'mode changed $prevMode→$newMode — restarting tunnel');
        await stop();
        // Brief gap so the old mode's teardown (utun remove / networksetup
        // restore) completes before the new mode sets up.
        await Future.delayed(const Duration(milliseconds: 500));
        await start();
      }
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
