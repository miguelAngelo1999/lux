import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';

/// Detects whether the corporate proxy is reachable and automatically
/// switches between proxy mode (corporate) and bypass mode (home/other).
///
/// When lux is always running as a local proxy (127.0.0.1:1090), apps never
/// need reconfiguration. This class just switches the routing rule:
/// - Corporate network → normal rule (traffic goes through upstream proxy)
/// - Home network → bypass_all (traffic goes direct through lux)
class NetworkDetector {
  final CoreManager coreManager;
  String? _lastActiveRule;
  bool _isCorpNetwork = true;

  NetworkDetector(this.coreManager);

  bool get isCorpNetwork => _isCorpNetwork;

  /// Probe the upstream proxy and switch rules accordingly.
  /// Returns true if on corporate network, false if at home.
  Future<bool> detect() async {
    try {
      // Get the configured proxy to probe
      final proxyList = await coreManager.getProxyList();
      final selectedProxy = proxyList.proxies.firstWhere(
        (p) => p.id == proxyList.id,
        orElse: () => proxyList.proxies.first,
      );

      if (selectedProxy.server == null || selectedProxy.server!.isEmpty) {
        _isCorpNetwork = false;
        return false;
      }

      // Try to TCP connect to the proxy server
      final isReachable = await _probeProxy(
        selectedProxy.server!,
        selectedProxy.port ?? 8080,
      );

      if (isReachable && !_isCorpNetwork) {
        // Switching TO corporate network
        _isCorpNetwork = true;
        await _restoreNormalRule();
        debugPrint('[NetworkDetector] Corporate proxy reachable → proxy mode');
      } else if (!isReachable && _isCorpNetwork) {
        // Switching TO home network
        _isCorpNetwork = false;
        await _switchToBypass();
        debugPrint('[NetworkDetector] Corporate proxy unreachable → bypass mode');
      }

      return _isCorpNetwork;
    } catch (e) {
      debugPrint('[NetworkDetector] Error: $e');
      return _isCorpNetwork;
    }
  }

  /// Switch to bypass_all rule — all traffic goes direct through lux.
  Future<void> _switchToBypass() async {
    try {
      // Save the current rule so we can restore it later
      final ruleList = await coreManager.getRuleList();
      if (ruleList.selectedId != 'bypass_all') {
        _lastActiveRule = ruleList.selectedId;
      }
      await coreManager.selectRule('bypass_all');
    } catch (e) {
      debugPrint('[NetworkDetector] Failed to switch to bypass: $e');
    }
  }

  /// Restore the normal (corporate) rule.
  Future<void> _restoreNormalRule() async {
    try {
      final target = _lastActiveRule ?? 'proxy_all';
      await coreManager.selectRule(target);
    } catch (e) {
      debugPrint('[NetworkDetector] Failed to restore rule: $e');
    }
  }

  /// TCP probe to check if the upstream proxy is reachable.
  Future<bool> _probeProxy(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
