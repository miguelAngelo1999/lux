import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lux/core/core_manager.dart';

/// Detects whether the corporate proxy is reachable and switches rules.
///
/// Stateless — no timers, no in-memory state. Rule selection is persisted
/// in config.json by lux_core so state survives restarts.
///
/// Call detect() on every network change. It probes the upstream proxy TCP
/// port directly (bypassing TUN) and switches rule accordingly:
///   - Proxy reachable  → selectRule('proxy_all')   — corporate network
///   - Proxy unreachable + direct works → selectRule('bypass_all') — home
///   - Both unreachable → no change (transient outage / VPN drop)
class NetworkDetector {
  final CoreManager coreManager;

  NetworkDetector(this.coreManager);

  void dispose() {}

  /// Probe the upstream proxy and switch rules if the network changed.
  /// Returns true if on corporate network, false if on home/direct network.
  Future<bool> detect() async {
    try {
      final proxyList = await coreManager.getProxyList();
      final selected = proxyList.proxies.firstWhere(
        (p) => p.id == proxyList.id,
        orElse: () => proxyList.proxies.first,
      );

      if (selected.server == null || selected.server!.isEmpty) {
        return false; // no proxy configured
      }

      final proxyReachable = await _probe(selected.server!, selected.port ?? 8080);

      if (proxyReachable) {
        // Corporate network — ensure proxy_all rule is active
        final ruleList = await coreManager.getRuleList();
        if (ruleList.selectedId != 'proxy_all') {
          await coreManager.selectRule('proxy_all');
          // Ensure lux_core is started
          if (!await coreManager.getIsStarted()) {
            await coreManager.start();
          }
          debugPrint('[NetworkDetector] proxy reachable → proxy_all');
        }
        return true;
      }

      // Proxy unreachable — check if direct internet works
      final directWorks = await _probeDirectConnectivity();
      if (directWorks) {
        final ruleList = await coreManager.getRuleList();
        if (ruleList.selectedId != 'bypass_all') {
          await coreManager.selectRule('bypass_all');
          debugPrint('[NetworkDetector] proxy unreachable, direct works → bypass_all');
        }
        return false;
      }

      // Both unreachable — transient outage, don't change anything
      debugPrint('[NetworkDetector] both unreachable — no change');
      return false;
    } catch (e) {
      debugPrint('[NetworkDetector] error: $e');
      return false;
    }
  }

  /// TCP probe — bypasses TUN by connecting directly via the OS stack.
  Future<bool> _probe(String host, int port,
      {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Confirm direct internet by probing two well-known endpoints.
  Future<bool> _probeDirectConnectivity() async {
    int ok = 0;
    for (final (host, port) in [('1.1.1.1', 443), ('8.8.8.8', 53)]) {
      if (await _probe(host, port, timeout: const Duration(seconds: 5))) ok++;
    }
    return ok >= 1; // at least one must succeed
  }
}
