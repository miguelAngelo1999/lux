import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:lux/core/core_manager.dart';
import 'package:lux/util/app_log.dart';

/// Detects whether the corporate proxy is reachable and switches rules.
///
/// Stateless — no timers, no in-memory state. Rule selection is persisted
/// in config.json by lux_core so state survives restarts.
///
/// Detection strategy (in order):
///   1. If a PAC URL is active → probe the PAC server (most universal)
///   2. If no PAC → probe the configured proxy server directly
///
/// This works for any corporate network worldwide — no hardcoded addresses.
class NetworkDetector {
  final CoreManager coreManager;

  NetworkDetector(this.coreManager);

  void dispose() {}

  /// Probe the network and switch rules if needed.
  /// Returns true if on corporate network, false if on home/direct network.
  Future<bool> detect() async {
    appLog('NET-DETECT', 'starting network detection');
    try {
      // ── Strategy 1: Use PAC URL if available ─────────────────────────────
      // The PAC server is on the corporate LAN — reachable only on corp network.
      // This works regardless of which proxy server is configured.
      final pacStatus = await coreManager.getPacStatus();
      final pacUrl = pacStatus['url'] as String? ?? '';
      final pacActive = pacStatus['active'] as bool? ?? false;

      if (pacUrl.isNotEmpty) {
        appLog('NET-DETECT', 'probing PAC server: $pacUrl');
        final pacReachable = await _probePacUrl(pacUrl);

        if (pacReachable) {
          appLog('NET-DETECT', 'PAC server reachable → corporate network');
          await _ensureRule('proxy_all');
          return true;
        } else {
          appLog('NET-DETECT', 'PAC server unreachable → not on corporate network');
          // Confirm direct internet works before switching
          final directWorks = await _probeDirectConnectivity();
          if (directWorks) {
            appLog('NET-DETECT', 'direct internet works → switching to bypass_all');
            await _ensureRule('bypass_all');
            return false;
          } else {
            appLog('NET-DETECT', 'PAC unreachable + direct also unreachable → transient outage, no change');
            return false;
          }
        }
      }

      // ── Strategy 2: No PAC — probe the configured proxy server directly ──
      appLog('NET-DETECT', 'no PAC URL active — falling back to proxy server probe');
      final proxyList = await coreManager.getProxyList();
      final selected = proxyList.proxies.firstWhere(
        (p) => p.id == proxyList.id,
        orElse: () => proxyList.proxies.first,
      );

      if (selected.server == null || selected.server!.isEmpty) {
        appLog('NET-DETECT', 'no proxy configured — skipping');
        return false;
      }

      appLog('NET-DETECT', 'probing proxy server: ${selected.server}:${selected.port ?? 8080}');
      final proxyReachable = await _probe(selected.server!, selected.port ?? 8080);

      if (proxyReachable) {
        appLog('NET-DETECT', 'proxy server reachable → corporate network');
        await _ensureRule('proxy_all');
        return true;
      } else {
        final directWorks = await _probeDirectConnectivity();
        if (directWorks) {
          appLog('NET-DETECT', 'proxy unreachable + direct works → bypass_all');
          await _ensureRule('bypass_all');
          return false;
        }
        appLog('NET-DETECT', 'proxy + direct both unreachable → transient outage, no change');
        return false;
      }
    } catch (e) {
      appLog('NET-DETECT', 'error: $e');
      debugPrint('[NetworkDetector] error: $e');
      return false;
    }
  }

  /// Switch rule only if it's not already set.
  Future<void> _ensureRule(String rule) async {
    try {
      final ruleList = await coreManager.getRuleList();
      if (ruleList.selectedId != rule) {
        appLog('NET-DETECT', 'was ${ruleList.selectedId} → switching to $rule');
        await coreManager.selectRule(rule);
        // On corporate → ensure lux_core is started
        if (rule == 'proxy_all' && !await coreManager.getIsStarted()) {
          appLog('NET-DETECT', 'lux_core not started — calling start()');
          await coreManager.start();
        }
      } else {
        appLog('NET-DETECT', 'already on $rule — no change');
      }
    } catch (e) {
      appLog('NET-DETECT', 'rule switch error: $e');
    }
  }

  /// Probe a PAC/WPAD URL via HTTP. The PAC server is on the corporate LAN.
  /// Reachable only when on corporate network.
  Future<bool> _probePacUrl(String pacUrl,
      {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      // Extract host:port from URL
      final uri = Uri.tryParse(pacUrl);
      if (uri == null) return false;
      final host = uri.host;
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      appLog('NET-DETECT', 'PAC probe $host:$port ✓');
      return true;
    } catch (e) {
      appLog('NET-DETECT', 'PAC probe failed: $e');
      return false;
    }
  }

  /// TCP probe — direct socket connection bypassing TUN.
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
      if (await _probe(host, port, timeout: const Duration(seconds: 5))) {
        ok++;
        appLog('NET-DETECT', 'direct probe $host:$port ✓');
      } else {
        appLog('NET-DETECT', 'direct probe $host:$port ✗');
      }
    }
    appLog('NET-DETECT', 'direct connectivity: $ok/2');
    return ok >= 1;
  }
}
