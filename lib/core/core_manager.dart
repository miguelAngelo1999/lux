import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:lux/error.dart';
import 'package:lux/util/process_manager.dart';
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
  }

  Future<void> start() async {
    await dio.post('$baseHttpUrl/manager/start',
        options: Options(
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ));
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
    return items.map((e) => CustomizedRuleItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> addCustomizedRules(List<String> rules) async {
    await dio.put('$baseHttpUrl/rules/customized', data: {'rules': rules});
  }

  Future<void> editCustomizedRule(String oldRule, String newRule) async {
    await dio.post('$baseHttpUrl/rules/customized', data: {'oldRule': oldRule, 'newRule': newRule});
  }

  Future<void> deleteCustomizedRules(List<String> rules) async {
    await dio.delete('$baseHttpUrl/rules/customized', data: {'rules': rules});
  }

  Future<void> reorderCustomizedRules(List<String> rules) async {
    await dio.post('$baseHttpUrl/rules/customized/reorder', data: {'rules': rules});
  }

  Future<void> toggleCustomizedRule(String rule) async {
    await dio.post('$baseHttpUrl/rules/customized/toggle', data: {'rule': rule});
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

  Future<void> selectProxy(String id) async {
    await dio.post('$baseHttpUrl/selected/proxy', data: {'id': id});
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

  /// Updates an existing proxy.
  Future<void> updateProxy(String id, Map<String, dynamic> proxy) async {
    await dio.post('$baseHttpUrl/proxies/$id', data: proxy);
  }

  /// Save settings — reads current raw config and merges only the changed fields.
  /// Never overwrites DNS server lists or other fields not managed by the settings page.
  Future<void> saveSetting(Setting setting) async {
    final current = await dio.get('$baseHttpUrl/setting');
    final raw = Map<String, dynamic>.from(current.data['setting'] as Map);

    // Only update fields the settings page manages
    raw['mode'] = setting.mode == ProxyMode.tun
        ? 'tun'
        : setting.mode == ProxyMode.system
            ? 'system'
            : 'mixed';
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

  // ── SSL Inspection ─────────────────────────────────────────────────────────

  /// Probes for SSL bumping. Returns the parsed status map from the backend.
  /// Keys: detected (bool), checkedAt (String), error (String?), hasCert (bool).
  Future<SslBumpStatus> getSslBumpStatus() async {
    try {
      final res = await dio.get('$baseHttpUrl/ssl-inspect/status',
          options: Options(receiveTimeout: const Duration(seconds: 20)));
      return SslBumpStatus.fromJson(res.data as Map<String, dynamic>);
    } catch (e) {
      return SslBumpStatus(
        detected: false,
        hasCert: false,
        error: e.toString(),
      );
    }
  }

  /// Downloads the captured intercept CA cert as PEM bytes.
  /// Returns null if no cert is available.
  Future<List<int>?> getSslBumpCert() async {
    try {
      final res = await dio.get<List<int>>(
        '$baseHttpUrl/ssl-inspect/cert',
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      if (res.statusCode == 200 && res.data != null && res.data!.isNotEmpty) {
        return res.data;
      }
      return null;
    } catch (e) {
      debugPrint('getSslBumpCert error: $e');
      return null;
    }
  }
}
