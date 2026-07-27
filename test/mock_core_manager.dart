import 'dart:typed_data';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Minimal mock CoreManager for widget tests.
/// Returns sensible defaults for all calls so widgets render without crashing.
class MockCoreManager implements CoreManager {
  bool isStarted = true;
  String selectedRule = 'proxy_all';
  Setting _setting = const Setting();
  final List<ProxyDetail> _proxies = [];

  @override
  Future<bool> getIsStarted() async => isStarted;

  @override
  Future<Setting> getSetting() async => _setting;

  @override
  Future<void> saveSetting(Setting s) async { _setting = s; }

  @override
  Future<ProxyList> getProxyList() async => ProxyList(
    id: 'mock-proxy',
    proxies: [
      ProxyDetail(
        id: 'mock-proxy',
        name: 'Test Proxy',
        type: 'http',
        server: '10.8.0.1',
        port: 8082,
      ),
    ],
  );

  @override
  Future<void> selectProxy(String id) async {}

  @override
  Future<RuleList> getRuleList() async => RuleList(
    selectedId: selectedRule,
    rules: [
      RuleItem(id: 'proxy_all', name: 'Proxy All', isBuiltIn: true),
      RuleItem(id: 'bypass_all', name: 'Bypass All', isBuiltIn: true),
    ],
  );

  @override
  Future<void> selectRule(String id) async { selectedRule = id; }

  @override
  Future<void> start() async { isStarted = true; }

  @override
  Future<void> stop() async { isStarted = false; }

  @override
  Future<void> restart() async {}

  @override
  Future<HealthResult> getHealth() async =>
      HealthResult(ok: true, latency: 10, error: '');

  @override
  Future<DetectedProxy?> detectNetworkProxy() async => null;

  @override
  Future<SslBumpStatus> getSslBumpStatus({String? proxyAddr, bool fresh = false}) async =>
      SslBumpStatus(detected: false, hasCert: false, certInfo: null);

  @override
  Future<void> run({void Function()? onReady, void Function(String)? onError}) async {
    onReady?.call();
  }

  @override
  Future<void> safeExit() async {}

  @override
  Future<void> addProxy(Map<String, dynamic> proxy) async { }

  @override
  Future<void> updateProxy(String id, Map<String, dynamic> proxy) async {}

  @override
  Future<void> deleteProxy(String id) async {}

  @override
  Future<ProxyDetail> getProxyDetail(String id) async =>
      ProxyDetail(id: id, name: 'Mock', type: 'http', server: 'test', port: 8080);

  @override
  Future<int> testProxyLatency(String id) async => 50;

  @override
  Future<Map<String, dynamic>> getMitmSettings() async => {'enabled': false};

  @override
  Future<void> setMitmEnabled(bool v) async {}

  @override
  Future<List<int>?> getMitmCAPem() async => null;

  @override
  Future<void> addMitmPattern(String pattern) async {}

  @override
  Future<void> deleteMitmPattern(String pattern) async {}

  @override
  Future<List<CustomizedRuleItem>> getCustomizedRules() async => [];

  @override
  Future<void> addCustomizedRule(CustomizedRuleItem rule) async {}

  @override
  Future<void> updateCustomizedRule(String id, CustomizedRuleItem rule) async {}

  @override
  Future<void> deleteCustomizedRule(String id) async {}

  @override
  Future<void> reorderCustomizedRules(List<String> ids) async {}

  @override
  Future<void> closeAllConnections() async {}

  @override
  Future<WebSocketChannel> getLogChannel() async =>
      throw UnimplementedError('use real channel in integration tests');

  @override
  Future<WebSocketChannel> getConnectionsChannel() async =>
      throw UnimplementedError();

  @override
  Future<WebSocketChannel?> getTrafficChannel() async => null;

  @override
  Future<WebSocketChannel?> getRuntimeStatusChannel() async => null;

  @override
  Future<WebSocketChannel?> getEventChannel() async => null;

  @override
  void clearTrafficChannel() {}

  @override
  void clearRuntimeStatusChannel() {}

  // Ignore any extra methods CoreManager may have that we don't need in tests
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
