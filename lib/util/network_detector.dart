import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:lux/core/core_config.dart';
import 'package:lux/core/core_manager.dart';

/// Detects whether the corporate proxy is reachable and automatically
/// switches between proxy mode (corporate) and bypass mode (home/other).
///
/// Switching logic:
/// - Proxy reachable → proxy mode (corporate network)
/// - Proxy unreachable 3× in a row + direct connectivity works → bypass_all
/// - Proxy unreachable + direct ALSO fails → stay current, poll every 60s
///
/// Requiring 3 consecutive failures prevents a single proxy blip from
/// triggering a bypass switch on corporate networks.
class NetworkDetector {
  final CoreManager coreManager;
  String? _lastActiveRule;
  bool _isCorpNetwork = true;
  bool _disposed = false;
  Timer? _recoveryTimer;

  /// How many consecutive times the proxy must be unreachable before
  /// switching to bypass_all. Prevents false switches on transient blips.
  static const _failThreshold = 3;
  int _consecutiveProxyFailures = 0;

  NetworkDetector(this.coreManager);

  bool get isCorpNetwork => _isCorpNetwork;

  void dispose() {
    _disposed = true;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
  }

  /// Probe the upstream proxy and switch rules accordingly.
  /// Called on network changes and periodically when proxy is down.
  Future<bool> detect() async {
    if (_disposed) return _isCorpNetwork;
    try {
      final proxyList = await coreManager.getProxyList();
      final selectedProxy = proxyList.proxies.firstWhere(
        (p) => p.id == proxyList.id,
        orElse: () => proxyList.proxies.first,
      );

      if (selectedProxy.server == null || selectedProxy.server!.isEmpty) {
        _isCorpNetwork = false;
        _stopRecoveryTimer();
        return false;
      }

      final isProxyReachable = await _probeProxy(
        selectedProxy.server!,
        selectedProxy.port ?? 8080,
      );

      final ruleList = await coreManager.getRuleList();
      final isCurrentlyBypassed = ruleList.selectedId == 'bypass_all';

      if (isProxyReachable) {
        // Proxy is up — reset failure counter, cancel recovery polling
        _consecutiveProxyFailures = 0;
        _stopRecoveryTimer();
        if (!_isCorpNetwork || isCurrentlyBypassed) {
          _isCorpNetwork = true;
          await _restoreNormalRule();
          debugPrint('[NetworkDetector] Corporate proxy reachable → proxy mode restored');
        }
      } else {
        _consecutiveProxyFailures++;
        debugPrint('[NetworkDetector] Proxy unreachable (consecutive failures: $_consecutiveProxyFailures/$_failThreshold)');

        if (_consecutiveProxyFailures < _failThreshold) {
          // Not enough failures yet — don't switch, just wait for next detect() call
          debugPrint('[NetworkDetector] Below threshold — not switching yet');
          return _isCorpNetwork;
        }

        // Proxy has been unreachable _failThreshold times — check direct connectivity
        final isDirectWorking = await _probeDirectConnectivity();

        if (isDirectWorking) {
          // Likely home network — switch to bypass, but keep polling proxy
          // so we switch back the moment it comes back (e.g. VPN reconnects)
          if (_isCorpNetwork) {
            _isCorpNetwork = false;
            await _switchToBypass();
            debugPrint('[NetworkDetector] Proxy unreachable ${_consecutiveProxyFailures}×, direct works → bypass mode');
          }
          // Always start/keep recovery polling so we auto-recover when proxy returns
          _startRecoveryTimer(selectedProxy.server!, selectedProxy.port ?? 8080);
        } else {
          // VPN drop / transient outage — stay on current rule, start polling
          debugPrint('[NetworkDetector] Proxy AND direct unreachable → VPN drop, polling every 60s');
          _startRecoveryTimer(selectedProxy.server!, selectedProxy.port ?? 8080);
        }
      }

      return _isCorpNetwork;
    } catch (e) {
      debugPrint('[NetworkDetector] Error: $e');
      return _isCorpNetwork;
    }
  }

  /// Starts a 60s polling timer that re-probes the proxy.
  /// When the proxy comes back (VPN reconnects), restores the rule immediately.
  void _startRecoveryTimer(String host, int port) {
    if (_recoveryTimer != null) return; // already running
    debugPrint('[NetworkDetector] Starting 60s recovery polling for $host:$port');
    _recoveryTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (_disposed) {
        _stopRecoveryTimer();
        return;
      }
      debugPrint('[NetworkDetector] Recovery poll — probing $host:$port');
      final reachable = await _probeProxy(host, port);
      if (reachable) {
        debugPrint('[NetworkDetector] Proxy $host:$port is back → restoring rule');
        _stopRecoveryTimer();
        _consecutiveProxyFailures = 0;
        _isCorpNetwork = true;
        await _restoreNormalRule();
      }
    });
  }

  void _stopRecoveryTimer() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
  }

  /// Probe direct internet connectivity by TCP-connecting to well-known hosts.
  /// Uses a longer timeout (5s) to avoid false positives from slow responses.
  Future<bool> _probeDirectConnectivity() async {
    final targets = [
      ('1.1.1.1', 443),
      ('8.8.8.8', 53),
      ('1.0.0.1', 443),
    ];
    int successes = 0;
    for (final (host, port) in targets) {
      if (await _probeProxy(host, port, timeout: const Duration(seconds: 5))) {
        successes++;
        debugPrint('[NetworkDetector] Direct connectivity confirmed via $host:$port');
      }
    }
    // Require at least 2 out of 3 to succeed to confirm we're on a non-corp network
    final confirmed = successes >= 2;
    debugPrint('[NetworkDetector] Direct connectivity: $successes/3 — confirmed=$confirmed');
    return confirmed;
  }

  /// Switch to bypass_all rule.
  Future<void> _switchToBypass() async {
    try {
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
      debugPrint('[NetworkDetector] Restored rule: $target');
    } catch (e) {
      debugPrint('[NetworkDetector] Failed to restore rule: $e');
    }
  }

  /// TCP probe to check if a host:port is reachable.
  Future<bool> _probeProxy(String host, int port,
      {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
